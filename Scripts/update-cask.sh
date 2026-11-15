#!/bin/zsh
# Point the Homebrew cask in howon-kim/homebrew-tap at a published release.
#   Scripts/update-cask.sh 0.1.0 <sha256>
set -euo pipefail
VERSION=${1:?usage: Scripts/update-cask.sh <version> <sha256>}
SHA=${2:?usage: Scripts/update-cask.sh <version> <sha256>}
ROOT=${0:A:h:h}
TAP_REPO=${TAP_REPO:-howon-kim/homebrew-tap}
WORK="$ROOT/.build/homebrew-tap"

rm -rf "$WORK"
gh repo clone "$TAP_REPO" "$WORK" -- --quiet
mkdir -p "$WORK/Casks"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" \
  -e '/^# Copy to /,/^# update /d' \
  "$ROOT/packaging/homebrew/bananashell.rb" > "$WORK/Casks/bananashell.rb"
cd "$WORK"
if git diff --quiet && [[ -z $(git status --porcelain) ]]; then
  echo "Cask already at $VERSION."; exit 0
fi
git add Casks/bananashell.rb
git commit -q -m "bananashell $VERSION"
git push -q origin HEAD
echo "Cask updated to $VERSION."
