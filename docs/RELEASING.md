# Releasing bananaShell

Releases are Developer ID–signed, notarized disk images published on GitHub
Releases. Installed copies update themselves through [Sparkle](https://sparkle-project.org).

## One-time setup

1. **Developer ID certificate** — "Developer ID Application" in the login keychain
   (`security find-identity -v -p codesigning`).
2. **Notarization credentials** — create an app-specific password at
   [account.apple.com](https://account.apple.com) → Sign-In and Security, then:
   ```sh
   xcrun notarytool store-credentials bananaShell-notary \
     --apple-id <your Apple ID> --team-id 48BUATF4VW
   ```
3. **Sparkle signing key** — already generated in the login keychain under the
   account `bananaShell`; its public half is `SUPublicEDKey` in
   `NotificationDefaults.plist`. Back up the private key once:
   ```sh
   .build/MultiWindow/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
     --account bananaShell -x ~/bananaShell-sparkle-private-key
   ```
   Store that file in a password manager and delete it. **If the key is lost,
   existing installs can no longer verify updates.**
4. `gh auth login`

## Each release

```sh
Scripts/release.sh 0.2.0            # draft release to review
Scripts/release.sh 0.2.0 --publish  # or publish immediately
```

The script refuses to run with uncommitted changes, then:

1. archives the Release configuration (hardened runtime, `bananaShell.entitlements`),
   with `CFBundleVersion` = commit count;
2. exports with Developer ID, notarizes and staples the app;
3. builds `bananaShell-<version>.dmg`, signs, notarizes and staples it;
4. signs the DMG for Sparkle and writes `appcast.xml`;
5. tags `v<version>` and creates the GitHub release with the DMG and appcast.

Sparkle reads `https://github.com/howon-kim/bananaShell/releases/latest/download/appcast.xml`,
which always points at the newest **published, non-prerelease** release, so a draft
reaches nobody until you publish it.

## Homebrew

After publishing, copy `packaging/homebrew/bananashell.rb` into
`Casks/bananashell.rb` of the `howon-kim/homebrew-tap` repository, set `version`
and the `sha256` printed by the script. Users install with:

```sh
brew install --cask howon-kim/tap/bananashell
```

The cask installs `tmux`, which bananaShell needs.
