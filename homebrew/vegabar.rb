# Homebrew cask for VegaBar.
#
# This file lives in a separate "tap" repository, github.com/dasmart/homebrew-tap,
# as Casks/vegabar.rb. Users then run:
#
#   brew install --cask dasmart/tap/vegabar
#
# After each release, update `version` and `sha256` (the release workflow
# prints the checksum, and the release notes show it). Releases are signed
# with Developer ID and notarized, so the app opens without any Gatekeeper
# workaround.
cask "vegabar" do
  version "0.4.0"
  sha256 "8aa9279c3a941e023d0481089d735cd5bac0255290f89c101beec471d0a8142e"

  url "https://github.com/dasmart/VegaBar/releases/download/v#{version}/VegaBar.zip"
  name "VegaBar"
  desc "Menubar controller for Zhiyun Bluetooth lights"
  homepage "https://github.com/dasmart/VegaBar"

  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "VegaBar.app"
  binary "#{appdir}/VegaBar.app/Contents/Helpers/vegabar"

  zap trash: [
    "~/Library/Application Support/VegaBar",
    "~/Library/Logs/VegaBar.log",
    "~/Library/Preferences/org.dasmart.vegabar.plist",
  ]
end
