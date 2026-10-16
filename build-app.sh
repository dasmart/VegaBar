#!/bin/bash
# Builds a universal (Apple silicon + Intel) VegaBar.app into ./build.
#
# Xcode builds everything ad-hoc signed (the Swift package dependencies insist
# on automatic signing, so a real identity can't be passed to xcodebuild), and
# the finished bundle is then signed as one unit with the identity you choose:
#   VEGABAR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"
#   (or "Apple Development: …", or a certificate SHA-1 from `security find-identity`)
# Unset, the app stays ad-hoc signed, which is fine on the Mac that built it.
# Set VEGABAR_ZIP=1 to also produce build/VegaBar.zip (as attached to releases).
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

IDENTITY="${VEGABAR_SIGN_IDENTITY:--}"
LOG=.build/xcodebuild.log
mkdir -p .build
if ! xcodebuild -project VegaBar.xcodeproj -scheme VegaBar -configuration Release \
     -derivedDataPath .build/xcode -destination 'generic/platform=macOS' \
     ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
     build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -40
  echo "Build failed (full log: $LOG)"; exit 1
fi
grep -E "warning: " "$LOG" | grep -v "/checkouts/\|SourcePackages" | sort -u | head -20 || true

APP=.build/xcode/Build/Products/Release/VegaBar.app
rm -rf build && mkdir -p build && cp -R "$APP" build/
# Sign the whole bundle (app + embedded CLI) as one unit. A secure timestamp
# is required for notarization and meaningless for ad-hoc signatures.
if [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --options runtime --sign - build/VegaBar.app
else
  codesign --force --deep --options runtime --timestamp --sign "$IDENTITY" build/VegaBar.app
fi
codesign --verify --deep --strict build/VegaBar.app
echo "Built build/VegaBar.app ($(lipo -archs build/VegaBar.app/Contents/MacOS/VegaBar)), signed by: $(codesign -dv build/VegaBar.app 2>&1 | grep -E '^Authority=' | head -1 | cut -d= -f2 || echo ad-hoc)"
if [ "${VEGABAR_ZIP:-0}" = "1" ]; then
  ditto -c -k --keepParent build/VegaBar.app build/VegaBar.zip
  echo "Zipped build/VegaBar.zip"
fi
