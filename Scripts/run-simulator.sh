#!/bin/bash
# Build, install, and launch RenderiOS on a booted simulator.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
echo "==> Repo root: $REPO_ROOT"
SIMULATOR="${1:-iPhone 17 Pro}"
echo "==> Simulator: $SIMULATOR"
DERIVED_DATA="$REPO_ROOT/build/DerivedData"
BUNDLE_ID="com.veverkap.RenderiOS"

cd "$REPO_ROOT"

echo "==> Building for $SIMULATOR"
xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOS \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -derivedDataPath "$DERIVED_DATA" \
  build | grep -E 'error:|warning: .*RenderiOS|BUILD' || true

DEVICE=$(xcrun simctl list devices available \
  | grep -E "^[[:space:]]+$SIMULATOR \(" | head -1 | sed 's/.*(\([0-9A-F-]*\)).*/\1/')
# Anchored to the start of the name, not a substring match: since CI got its own device, a plain
# `grep "iPhone 17 Pro ("` also matches "CI iPhone 17 Pro" — and launching onto the test device while
# you're watching the other one looks exactly like the app failing to start.
if [ -z "$DEVICE" ]; then
  echo "!!! No available simulator named '$SIMULATOR'" >&2
  exit 1
fi

echo "==> Booting $SIMULATOR ($DEVICE)"
xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
open -a Simulator

echo "==> Installing and launching"
xcrun simctl install "$DEVICE" "$DERIVED_DATA/Build/Products/Debug-iphonesimulator/RenderiOS.app"
xcrun simctl launch "$DEVICE" "$BUNDLE_ID"
