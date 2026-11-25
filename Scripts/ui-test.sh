#!/bin/bash
# Run the UI tests against Render's live API and copy their screenshots to build/ui-tests/screens.
#
# Unlike `make walkthrough`, this never opens the Simulator window or moves the mouse: xcodebuild
# boots the device headless and XCUITest taps inside the simulator. You can keep working while it runs.
#
#   make ui-test                                    # every UI test
#   make ui-test ONLY=ServiceScreensTests           # one class (or Class/testMethod)
#   make ui-test TEXT_SIZE=AccessibilityM           # at a Dynamic Type size
#   make ui-test UI_SERVICE=docmost-va              # tests read UI_* variables via AppDriver.value
#
# Signs in with RENDER_API_KEY from .env. The simulator's keychain is reset first, so the app always
# starts signed out and a key swapped in .env takes effect. That signs out every app on *that*
# simulator, the same as `make walkthrough`.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; . ./.env; set +a; fi
if [ -z "${RENDER_API_KEY:-}" ]; then
  echo "!!! RENDER_API_KEY isn't set. Put a key in .env." >&2
  exit 1
fi

SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
# test-destination.sh picks the simulator by UDID, so its runtime matches the SDK.
DEVICE=$(Scripts/test-destination.sh "$SIMULATOR" | sed -n 's/.*id=\([0-9A-F-]*\).*/\1/p')
if [ -z "$DEVICE" ]; then
  echo "!!! No simulator found for \"$SIMULATOR\"." >&2
  exit 1
fi
NAME=$(xcrun simctl list devices available | grep "($DEVICE)" | head -1 | sed 's/^[[:space:]]*\(.*\) ([0-9A-F-]*).*/\1/')

OUT=build/ui-tests
rm -rf "$OUT"
mkdir -p "$OUT"

# `simctl boot` starts the device without the Simulator app; the keychain reset needs it running.
xcrun simctl boot "$DEVICE" 2> /dev/null || true
xcrun simctl bootstatus "$DEVICE" -b > /dev/null
xcrun simctl keychain "$DEVICE" reset

ARGS=()
if [ -n "${ONLY:-}" ]; then ARGS+=("-only-testing:RenderiOSUITests/$ONLY"); fi

# xcodebuild passes TEST_RUNNER_<NAME> to the test runner as <NAME>; that's how AppDriver reads them.
export TEST_RUNNER_RENDER_API_KEY="$RENDER_API_KEY"
export TEST_RUNNER_UI_TEXT_SIZE="${TEXT_SIZE:-}"
while IFS='=' read -r key value; do
  export "TEST_RUNNER_$key=$value"
done < <(env | grep -E '^UI_[A-Z_]+=' || true)

echo "==> Running UI tests on $NAME ($DEVICE), headless"
status=0
xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOSUITests \
  -destination "id=$DEVICE" -resultBundlePath "$OUT/Result.xcresult" \
  ${XCODEBUILD_FLAGS:-} "${ARGS[@]+"${ARGS[@]}"}" test > "$OUT/xcodebuild.log" 2>&1 || status=$?
grep -E "Test Case .* (passed|failed|skipped)|error: |\*\* TEST" "$OUT/xcodebuild.log" || true

# Screenshots are saved as attachments. Export them and name each file after the test and the
# name AppDriver.screenshot gave it, so ServiceScreensTests/testServiceList's "service" becomes
# ServiceScreensTests.testServiceList.service.png.
if [ -d "$OUT/Result.xcresult" ]; then
  xcrun xcresulttool export attachments --path "$OUT/Result.xcresult" --output-path "$OUT/raw" > /dev/null
  mkdir -p "$OUT/screens"
  python3 - "$OUT" <<'EOF'
import json, os, re, shutil, sys
out = sys.argv[1]
for test in json.load(open(f"{out}/raw/manifest.json")):
    prefix = re.sub(r"[^A-Za-z0-9]+", ".", test["testIdentifier"]).strip(".")
    for a in test["attachments"]:
        # suggestedHumanReadableName is "<name>_<n>_<uuid>.png"; keep the name. Only PNGs:
        # XCTest adds its own recordings, UI trees and snapshots on a failure.
        name = re.sub(r"_\d+_[0-9A-F-]{36}(\.\w+)$", r"\1", a["suggestedHumanReadableName"])
        if not name.endswith(".png") or name.startswith(("Screen Recording", "UI Snapshot")):
            continue
        shutil.copy(f"{out}/raw/{a['exportedFileName']}", f"{out}/screens/{prefix}.{name}")
EOF
  echo "==> Screenshots in $OUT/screens:"
  ls "$OUT/screens"
fi
exit $status
