#!/bin/zsh
# Build, sign, notarize and publish a bananaShell release.
#
#   Scripts/release.sh 0.1.0            # creates a draft GitHub release
#   Scripts/release.sh 0.1.0 --publish  # publishes it (Sparkle clients see it)
#
# One-time setup (see docs/RELEASING.md):
#   - "Developer ID Application" certificate in the login keychain
#   - xcrun notarytool store-credentials bananaShell-notary ...
#   - Sparkle EdDSA key in the keychain (generate_keys --account bananaShell)
#   - gh auth login
set -euo pipefail

VERSION=${1:?usage: Scripts/release.sh <version> [--publish]}
PUBLISH=${2:-}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "Version must look like 1.2.3" >&2; exit 1; }

ROOT=${0:A:h:h}
cd "$ROOT"
TEAM_ID=${TEAM_ID:-48BUATF4VW}
NOTARY_PROFILE=${NOTARY_PROFILE:-bananaShell-notary}
SPARKLE_ACCOUNT=${SPARKLE_ACCOUNT:-bananaShell}
REPO=${REPO:-howon-kim/bananaShell}
BUILD_NUMBER=$(git rev-list --count HEAD)
TAG="v$VERSION"
OUT="$ROOT/.build/release/$VERSION"
DERIVED="$ROOT/.build/release/DerivedData"
APP="$OUT/export/bananaShell.app"
DMG="$OUT/bananaShell-$VERSION.dmg"

step() { print -P "\n%F{yellow}==>%f $*"; }
# Apple's timestamp and notary services fail transiently; retry with backoff.
retry() {
  local attempt=1 max=4
  until "$@"; do
    (( attempt >= max )) && { echo "Failed after $max attempts: $*" >&2; return 1; }
    echo "Attempt $attempt failed; retrying in $(( attempt * 15 ))s…" >&2
    sleep $(( attempt * 15 )); (( attempt++ ))
  done
}

if [[ -n $(git status --porcelain) ]]; then
  echo "Working tree has uncommitted changes; commit them first so the release matches $TAG." >&2
  exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "Tag $TAG already exists." >&2
  exit 1
fi
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 || {
  echo "Notary profile '$NOTARY_PROFILE' is missing. Run:" >&2
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <id> --team-id $TEAM_ID" >&2
  exit 1
}
rm -rf "$OUT"; mkdir -p "$OUT"

step "Archiving $VERSION ($BUILD_NUMBER)"
xcodebuild -project bananaShell.xcodeproj -scheme bananaShell -configuration Release \
  -derivedDataPath "$DERIVED" -archivePath "$OUT/bananaShell.xcarchive" archive \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" -quiet

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
EOF
export_app() {
  rm -rf "$OUT/export"
  xcodebuild -exportArchive -archivePath "$OUT/bananaShell.xcarchive" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet
}
retry export_app
codesign --verify --deep --strict "$APP"

step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
# Fail on a rejected submission (notarytool exits 0 for "Invalid").
notarize() {
  local result
  result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json) || return 1
  print -r -- "$result" | grep -q '"status" *: *"Accepted"' && return 0
  print -r -- "$result" >&2
  [[ $result == *'"Invalid"'* ]] && { echo "Notarization rejected; see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE" >&2; exit 1; }
  return 1
}
retry notarize "$OUT/notarize.zip"
retry xcrun stapler staple "$APP"

step "Building the disk image"
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/bananaShell.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "bananaShell" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" -quiet
retry codesign --force --sign "Developer ID Application" --timestamp "$DMG"
retry notarize "$DMG"
retry xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"

step "Signing the update for Sparkle"
SIGN_UPDATE=$(find "$DERIVED/SourcePackages/artifacts" -path "*Sparkle/bin/sign_update" -type f | head -1)
[[ -x $SIGN_UPDATE ]] || { echo "sign_update not found" >&2; exit 1; }
SIGNATURE=$("$SIGN_UPDATE" --account "$SPARKLE_ACCOUNT" "$DMG")   # sparkle:edSignature="…" length="…"
DOWNLOAD="https://github.com/$REPO/releases/download/$TAG/bananaShell-$VERSION.dmg"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>bananaShell</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>$VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:releaseNotesLink>
      <enclosure url="$DOWNLOAD" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF

step "Creating GitHub release $TAG"
git tag -a "$TAG" -m "bananaShell $VERSION"
retry git push origin "$TAG"
FLAGS=(--draft)
[[ $PUBLISH == --publish ]] && FLAGS=()
gh release create "$TAG" "$DMG" "$OUT/appcast.xml" --repo "$REPO" --title "bananaShell $VERSION" --generate-notes "${FLAGS[@]}"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
print "\nDone: $DMG"
print "SHA-256 (for the Homebrew cask): $SHA"
if [[ $PUBLISH == --publish ]]; then
  step "Updating the Homebrew cask"
  "$ROOT/Scripts/update-cask.sh" "$VERSION" "$SHA"
else
  print "The release is a draft. Publish it on GitHub, then run:"
  print "  Scripts/update-cask.sh $VERSION $SHA"
fi
