#!/bin/bash
# Record a scripted walkthrough of the app, signing in with the API key from .env.
#
#   Scripts/record-walkthrough.sh                       # docs/walkthrough.mov
#   SERVICE=my-api Scripts/record-walkthrough.sh        # tour a different service
#   OUT=/tmp/demo.mov Scripts/record-walkthrough.sh
#
# Builds, reinstalls with the keychain wiped so the tour starts from onboarding, then drives the
# screens with sim-input.swift while `simctl io recordVideo` rolls. Writes the movie plus a caption
# file of timestamped beats next to it — simctl records no audio, so that's the narration script.
#
# For the OAuth device flow instead of a pasted key, use record-walkthrough-oauth.sh.
#
# Same two requirements as sim-input.swift: this terminal needs Accessibility permission, and the
# Mac must be unlocked with an awake display.
#
# **The recording shows real data** — workspace name, service names, log lines, request paths. Point
# it at a workspace you're willing to publish, or scrub the frames afterwards.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$REPO_ROOT/Scripts/walkthrough-lib.sh"

ENV_FILE="$REPO_ROOT/.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "!!! No .env file. Copy .env.example to .env and add your RENDER_API_KEY." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
if [ -z "${RENDER_API_KEY:-}" ]; then
  echo "!!! RENDER_API_KEY is empty in .env." >&2
  exit 1
fi

preflight
"$REPO_ROOT/Scripts/run-simulator.sh" "$SIMULATOR"
find_device
reset_app

trap stop_recording EXIT
start_recording

beat "Sign-in — the API key path" 3
tap "${ONBOARD_APIKEY[@]}"
beat "Pasting a key is the fallback; expanding it focuses the field" 2
# On stdin, never as an argument: an argument is visible in the process list. Same reason smoke.sh
# reads its key from .env.
printf '%s' "$RENDER_API_KEY" | swift "$REPO_ROOT/Scripts/sim-input.swift" type > /dev/null
beat "The key is validated against Render before it's stored, and only ever in the Keychain" 2
tap "${ONBOARD_CONTINUE[@]}"
sleep 5

tour
