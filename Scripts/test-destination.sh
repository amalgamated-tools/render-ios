#!/bin/bash
# Print an xcodebuild -destination for running the app target's unit tests.
#
# Tests need a *concrete* simulator: 'generic/platform=iOS Simulator' compiles but can't run, and
# pinning a device name breaks whenever GitHub rotates the simulator set installed on the runner.
# So: use $SIMULATOR when that device exists, and otherwise fall back to the last available iPhone
# (simctl lists runtimes oldest-first, so that's the newest one).
set -euo pipefail

PREFERRED="${1:-${SIMULATOR:-iPhone 17 Pro}}"
DEVICES=$(xcrun simctl list devices available)

if grep -qF "    $PREFERRED (" <<<"$DEVICES"; then
  echo "platform=iOS Simulator,name=$PREFERRED"
  exit 0
fi

FALLBACK=$(grep -oE '^    iPhone [^(]*' <<<"$DEVICES" | sed 's/ *$//;s/^ *//' | tail -1)
if [ -z "$FALLBACK" ]; then
  echo "!!! No available iPhone simulator to run tests on" >&2
  exit 1
fi
echo "platform=iOS Simulator,name=$FALLBACK"
