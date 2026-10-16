# Homebrew cask for VegaBar.
#
# This file lives in a separate "tap" repository, github.com/dasmart/homebrew-tap,
# as Casks/vegabar.rb. Users then run:
#
#   brew install --cask dasmart/tap/vegabar
#
# After each release, update `version` and `sha256` (the release workflow
# prints the checksum). The caveats about Gatekeeper can go once releases
# are notarized.
cask "vegabar" do
  version "0.3.0"
  sha256 "37b42aff9c9a6c5d603f40ded11165df1ef380e928cff9d055889e530a059101"

  url "https://github.com/dasmart/VegaBar/releases/download/v#{version}/VegaBar.zip"
  name "VegaBar"
  desc "Menubar controller for Zhiyun Bluetooth lights"
  homepage "https://github.com/dasmart/VegaBar"

  depends_on macos: ">= :sonoma"

  app "VegaBar.app"
  binary "#{appdir}/VegaBar.app/Contents/Helpers/vegabar"

  caveats <<~EOS
    VegaBar releases are not yet notarized, so macOS will refuse to open the
    app the first time. Open it once, click Done, then go to
    System Settings › Privacy & Security and click Open Anyway.
    Or, from Terminal:
      xattr -d com.apple.quarantine "#{appdir}/VegaBar.app"
  EOS

  zap trash: [
    "~/Library/Application Support/VegaBar",
    "~/Library/Logs/VegaBar.log",
    "~/Library/Preferences/org.dasmart.vegabar.plist",
  ]
end
