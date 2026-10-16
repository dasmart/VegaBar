#!/bin/bash
# Runs the unit tests (protocol encoder/parser, safety rules, URL parsing,
# schedule maths, settings migration). The test host launches VegaBar in test
# mode, which skips Bluetooth, the control socket and automations.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet
LOG=.build/xcodebuild-test.log
mkdir -p .build
# xcodebuild sometimes leaves the Debug test-host app running afterwards, where
# it would steal the vegabar:// URL scheme from the real app. Clean it up.
cleanup() { pkill -f "xcode-test/Build/Products/Debug/VegaBar.app" 2>/dev/null || true; }
trap cleanup EXIT
if xcodebuild test -project VegaBar.xcodeproj -scheme VegaBar -destination 'platform=macOS' \
     -derivedDataPath .build/xcode-test > "$LOG" 2>&1; then
  grep -E "Test Suite 'All tests'|Executed [0-9]+ tests" "$LOG" | tail -2
else
  grep -E "error:|failed|Executed" "$LOG" | grep -v "^$" | sort -u | head -40
  echo "Tests failed (full log: $LOG)"; exit 1
fi
