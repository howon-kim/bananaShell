# Homebrew cask for bananaShell.
# Copy to Casks/bananashell.rb in the howon-kim/homebrew-tap repository and
# update `version` and `sha256` (printed by Scripts/release.sh) for each release.
cask "bananashell" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_RELEASE_SCRIPT"

  url "https://github.com/howon-kim/bananaShell/releases/download/v#{version}/bananaShell-#{version}.dmg"
  name "bananaShell"
  desc "Terminal with persistent tmux sessions, grouped grids and a notch terminal"
  homepage "https://github.com/howon-kim/bananaShell"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :ventura"
  depends_on formula: "tmux"

  app "bananaShell.app"

  zap trash: [
    "~/Library/Application Support/bananaShell",
    "~/Library/Logs/bananaShell",
    "~/Library/Preferences/local.bananaShell.plist",
  ]
end
