#!/bin/bash
# Builds a universal (Apple silicon + Intel) VegaBar.app into ./build.
#
# Signing defaults to ad-hoc, which is fine for running on the Mac that built
# it. To sign with a real identity, set:
#   VEGABAR_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  (or "Apple Development: …")
#   VEGABAR_TEAM_ID=TEAMID
# Set VEGABAR_ZIP=1 to also produce build/VegaBar.zip (as attached to releases).
set -euo pipefail
cd "$(dirname "$0")"
command -v xcodegen >/dev/null || { echo "Install xcodegen: brew install xcodegen"; exit 1; }
xcodegen generate --quiet

IDENTITY="${VEGABAR_SIGN_IDENTITY:--}"
TEAM="${VEGABAR_TEAM_ID:-}"
LOG=.build/xcodebuild.log
mkdir -p .build
if ! xcodebuild -project VegaBar.xcodeproj -scheme VegaBar -configuration Release \
     -derivedDataPath .build/xcode -destination 'generic/platform=macOS' \
     ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
     CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
     build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u | head -40
  echo "Build failed (full log: $LOG)"; exit 1
fi
grep -E "warning: " "$LOG" | grep -v "/checkouts/\|SourcePackages" | sort -u | head -20 || true

APP=.build/xcode/Build/Products/Release/VegaBar.app
rm -rf build && mkdir -p build && cp -R "$APP" build/
# Re-sign the whole bundle (app + embedded CLI) as one unit so the signature
# covers everything, whichever identity was used.
codesign --force --deep --options runtime --sign "$IDENTITY" build/VegaBar.app
echo "Built build/VegaBar.app ($(lipo -archs build/VegaBar.app/Contents/MacOS/VegaBar))"
if [ "${VEGABAR_ZIP:-0}" = "1" ]; then
  ditto -c -k --keepParent build/VegaBar.app build/VegaBar.zip
  echo "Zipped build/VegaBar.zip"
fi
