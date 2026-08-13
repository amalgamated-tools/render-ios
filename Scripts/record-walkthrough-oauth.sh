#!/bin/bash
# Record the same walkthrough, but signing in through the OAuth device flow instead of a pasted key.
#
#   Scripts/record-walkthrough-oauth.sh                    # docs/walkthrough-oauth.mov
#   OPEN_IN_SIM=1 Scripts/record-walkthrough-oauth.sh      # approve inside the simulator's Safari
#   SERVICE=my-api Scripts/record-walkthrough-oauth.sh
#
# The device flow needs a human: the app shows a code, you approve it in a browser, and only then
# does the app get a token. That can't be synthesized, so this script stops and waits for you rather
# than pretending. The recording keeps rolling through the wait — trim it, or approve promptly.
#
# By default you approve on the **Mac**, off camera, and the simulator only ever shows the code and
# the spinner. `OPEN_IN_SIM=1` taps the in-app button instead, so the approval happens in the
# simulator's Safari and the whole flow is on camera — at the cost of putting a Render login on it.
#
# Everything after sign-in is identical to record-walkthrough.sh; both call `tour` in
# walkthrough-lib.sh. Same requirements: Accessibility permission, an unlocked Mac, real data on
# screen.
#
# One thing to know before publishing: the frames include the device code. It expires in ten minutes
# and is useless once approved, but it is a live credential for that long.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$REPO_ROOT/docs/walkthrough-oauth.mov}"
source "$REPO_ROOT/Scripts/walkthrough-lib.sh"

VERIFICATION_URL="https://dashboard.render.com/device-authorization"

preflight
"$REPO_ROOT/Scripts/run-simulator.sh" "$SIMULATOR"
find_device
reset_app

trap stop_recording EXIT
start_recording

beat "Sign-in — one tap, approve in the browser" 3
tap "${ONBOARD_SIGNIN[@]}"
beat "Render issues a code, and the app polls while you approve it" 5

if [ "${OPEN_IN_SIM:-0}" = "1" ]; then
  tap "${DEVICE_AUTH_OPEN[@]}"
  beat "The verification page opens with the code already filled in" 4
  echo
  echo "==> Approve in the simulator's Safari, then come back here."
else
  echo
  echo "==> Read the code off the simulator screen and approve it at:"
  echo "    $VERIFICATION_URL"
  open "$VERIFICATION_URL" 2> /dev/null || true
fi

echo "    The recording is still running — press Return once the app is signed in."
# `|| true` because read reports EOF as a failure, and under `set -e` that would abort the run —
# silently, on the one line whose whole job is to wait.
read -r _ || true
beat "Approved — the token lands in the Keychain and the app moves on" 3

tour
