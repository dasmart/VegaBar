#!/bin/bash
# Builds the Mac App Store version of VegaBar (configuration "AppStore":
# sandboxed, no CLI installer). See APPSTORE.md for the whole submission.
#
#   VEGABAR_TEAM_ID=ABCDE12345 ./build-appstore.sh
#       Archives and exports build/AppStore/VegaBar.pkg for App Store Connect,
#       signed automatically for your team. Upload it with Transporter, or
#       `xcrun altool --upload-app` / Xcode's Organizer. The team can also be
#       set in Configs/Team.xcconfig instead of the environment.
#
#   ./build-appstore.sh --local
#       Builds the same sandboxed app ad-hoc signed into build/AppStore-local,
#       to try the sandbox on this Mac without a developer account. There is
#       no team, so there is no App Group: the app works, but the bundled CLI
#       can't reach it. It has its own bundle id (org.dasmart.vegabar.sandboxtest)
#       so testing never creates the real app's container: macOS migrates
#       pairing data only when a container is first created, and a container
#       left by a test would stop that for the real App Store install.
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
mkdir -p .build

if [ "${1:-}" = "--local" ]; then
  LOG=.build/xcodebuild-appstore-local.log
  if ! xcodebuild -project VegaBar.xcodeproj -scheme VegaBar -configuration AppStore \
       -derivedDataPath .build/xcode-appstore -destination 'generic/platform=macOS' \
       ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
       CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
       VEGABAR_BUNDLE_SUFFIX=.sandboxtest \
       build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u | head -40
    echo "Build failed (full log: $LOG)"; exit 1
  fi
  rm -rf build/AppStore-local && mkdir -p build/AppStore-local
  cp -R .build/xcode-appstore/Build/Products/AppStore/VegaBar.app build/AppStore-local/
  APP=build/AppStore-local/VegaBar.app
  echo "Built $APP (local, ad-hoc, sandboxed)"
  codesign -d --entitlements - "$APP" 2>/dev/null | grep -E "app-sandbox|bluetooth|camera|application-groups" | sed 's/^/  app: /'
  codesign -d --entitlements - "$APP/Contents/Helpers/vegabar" 2>/dev/null | grep -E "app-sandbox|application-groups" | sed 's/^/  cli: /'
  exit 0
fi

TEAM="${VEGABAR_TEAM_ID:-}"
if [ -z "$TEAM" ] && [ -f Configs/Team.xcconfig ]; then
  TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]*\).*/\1/p' Configs/Team.xcconfig | head -1)
fi
[ -n "$TEAM" ] || { echo "Set VEGABAR_TEAM_ID or put DEVELOPMENT_TEAM in Configs/Team.xcconfig (see APPSTORE.md)."; exit 1; }

ARCHIVE=build/AppStore/VegaBar.xcarchive
LOG=.build/xcodebuild-appstore.log
rm -rf build/AppStore && mkdir -p build/AppStore
echo "Archiving for team $TEAM…"
if ! xcodebuild -project VegaBar.xcodeproj -scheme VegaBar -configuration AppStore \
     -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
     DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates \
     archive > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -40
  echo "Archive failed (full log: $LOG)"; exit 1
fi

OPTIONS=build/AppStore/ExportOptions.plist
cp Configs/ExportOptions-AppStore.plist "$OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $TEAM" "$OPTIONS"
echo "Exporting…"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTIONS" \
     -exportPath build/AppStore -allowProvisioningUpdates >> "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -40
  echo "Export failed (full log: $LOG)"; exit 1
fi
ls build/AppStore/*.pkg
echo "Ready to upload: build/AppStore/VegaBar.pkg (validate first in Transporter or Xcode's Organizer)."
