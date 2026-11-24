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

# Emit the device's UDID, not its name: a name alone makes xcodebuild assume OS:latest, which fails
# when the preferred device only exists on an older runtime (e.g. iPhone 17 Pro on 26.5, not 27.2).
# The last match is the one on the newest runtime that has it.
udid_for() {
  grep -F "    $1 (" <<<"$DEVICES" | tail -1 | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' || true
}

UDID=$(udid_for "$PREFERRED")
if [ -z "$UDID" ]; then
  FALLBACK=$(grep -oE '^    iPhone [^(]*' <<<"$DEVICES" | sed 's/ *$//;s/^ *//' | tail -1)
  if [ -z "$FALLBACK" ]; then
    echo "!!! No available iPhone simulator to run tests on" >&2
    exit 1
  fi
  UDID=$(udid_for "$FALLBACK")
fi
echo "platform=iOS Simulator,id=$UDID"
