#!/bin/bash
# Shared machinery for the walkthrough recorders: device lookup, a deterministic reset, screen
# recording, captions, and the post-sign-in tour itself.
#
# Sourced by record-walkthrough.sh (API key) and record-walkthrough-oauth.sh (device flow). The two
# differ only in how they get past onboarding; everything after that is `tour` below.
#
# Coordinates are in the pixel space of `xcrun simctl io <device> screenshot` on an **iPhone 17 Pro**
# (1206x2622), which is the same space sim-input.swift takes. They were read off screenshots during a
# live pass; a different device size needs a new pass. They also assume a **web service** — the
# drill-down card is a different height on a static site, so the row offsets move.
#
# Re-measured after the visual redesign, against a live workspace. Two things moved and one
# usefully didn't: the ONBOARD_* triple all shifted (the hero rebuilt that screen), and
# LIST_FIRST_RESULT dropped 30px as list rows grew glyph tiles. The DETAIL_* block did NOT move
# despite the detail screen gaining a header, because those rows are read with the screen scrolled
# to the bottom — see scroll_to_bottom. The LOGS_* coordinates were not re-checked; that screen was
# not touched by the redesign.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
SERVICE="${SERVICE:-mermaid-ssr}"
OUT="${OUT:-$REPO_ROOT/docs/walkthrough.mov}"
BUNDLE_ID="com.veverkap.RenderiOS"
# Matches run-simulator.sh, which does the build this script leans on.
APP="$REPO_ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/RenderiOS.app"

# --- taps, in screenshot pixels ------------------------------------------------------------------
ONBOARD_SIGNIN=(603 1848)     # "Sign in with Render"
ONBOARD_APIKEY=(282 2024)     # "Use an API key instead" — expanding it focuses the field
ONBOARD_CONTINUE=(601 2343)
DEVICE_AUTH_OPEN=(641 1589)   # "Open render.com to approve", on the device-flow waiting screen
LIST_SEARCH=(346 417)
LIST_FIRST_RESULT=(406 477)   # first row once the search field is active
LIST_ACCOUNT=(916 252)
LIST_SIGNOUT=(714 278)
NAV_BACK=(113 252)
DETAIL_ACTIONS=(1087 252)
# The drill-down rows, with the detail screen scrolled to the bottom.
DETAIL_DEPLOYS=(307 853)
DETAIL_LOGS=(270 1009)
DETAIL_METRICS=(300 1165)
DETAIL_EVENTS=(291 1321)
DEPLOY_FIRST_ROW=(524 498)
METRICS_24H=(739 419)
LOGS_FILTER=(915 252)
LOGS_FILTER_CANCEL=(176 300)  # the sheet is full-screen — there is no "outside" to tap
LOGS_MENU=(1082 252)
LOGS_LIVE_TAIL=(774 278)
LIST_CLEAR_SEARCH=(1089 276)
# A spot with nothing tappable under it, for dismissing a *menu* (which does close on an outside
# tap). Not usable on a sheet: a sheet covers the screen, so this would land on one of its rows.
SAFE_DISMISS=(200 1700)

DEVICE=""
RECORDER_PID=""
START_EPOCH=""
CAPTIONS=""

# --- helpers -------------------------------------------------------------------------------------

# Anchored to the start of the name: a plain substring match also finds "CI iPhone 17 Pro", and
# recording the wrong device looks exactly like the tour never running.
find_device() {
  DEVICE=$(xcrun simctl list devices available \
    | grep -E "^[[:space:]]+$SIMULATOR \(" | head -1 | sed 's/.*(\([0-9A-F-]*\)).*/\1/')
  if [ -z "$DEVICE" ]; then
    echo "!!! No available simulator named '$SIMULATOR'" >&2
    exit 1
  fi
  # sim-input.swift drives the window titled for this device; everything here targets simctl by
  # UDID, which stays unambiguous even if two devices ever share a name.
  export SIM_DEVICE="$SIMULATOR"
}

preflight() {
  if [ "$(ioreg -n Root -d1 -r | grep -c '"IOConsoleLocked" = Yes')" != "0" ]; then
    echo "!!! The Mac is locked. macOS drops synthesized taps while the console is locked, so the" >&2
    echo "    tour would record a screen that never moves. Unlock and re-run." >&2
    exit 1
  fi
}

tap() { swift "$REPO_ROOT/Scripts/sim-input.swift" tap "$1" "$2" > /dev/null; }
drag() { swift "$REPO_ROOT/Scripts/sim-input.swift" drag "$1" "$2" "$3" "$4" > /dev/null; }

# Scrolls a screen to its bottom. Two drags rather than one: past the end the list just rubber-bands,
# so overshooting is free, and it pins the layout to the bottom edge — which is what makes the
# drill-down row coordinates the same on every service.
scroll_to_bottom() {
  drag 601 2100 601 900
  sleep 0.6
  drag 601 2100 601 900
  sleep 1
}

# Prints a beat to the console and to the caption file, stamped at its offset into the recording.
# The caption file is what you'd narrate over or turn into subtitles; simctl records no audio.
beat() {
  local caption="$1" hold="${2:-2}"
  if [ -n "$START_EPOCH" ]; then
    local elapsed=$(( $(date +%s) - START_EPOCH ))
    printf '%02d:%02d  %s\n' $((elapsed / 60)) $((elapsed % 60)) "$caption" >> "$CAPTIONS"
  fi
  echo "  · $caption"
  sleep "$hold"
}

# Reinstalls the app with the keychain wiped, so the tour always starts from onboarding rather than
# from wherever the last run left the navigation stack. Without this the taps below drift: iOS
# restores the previous screen on launch, and a blind coordinate script then lands on the wrong rows.
reset_app() {
  echo "==> Resetting to a signed-out install"
  echo "    (this wipes the *simulator's* keychain — the device's other apps sign out too)"
  xcrun simctl terminate "$DEVICE" "$BUNDLE_ID" 2> /dev/null || true
  xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" 2> /dev/null || true
  xcrun simctl keychain "$DEVICE" reset
  xcrun simctl install "$DEVICE" "$APP"
  xcrun simctl launch "$DEVICE" "$BUNDLE_ID" > /dev/null
  # 4, not 3: the splash holds the logomark for a 700ms minimum before the first tappable frame,
  # and a tap that lands on the splash is silently swallowed.
  sleep 4
}

start_recording() {
  mkdir -p "$(dirname "$OUT")"
  CAPTIONS="${OUT%.*}.txt"
  : > "$CAPTIONS"
  echo "==> Recording to $OUT"
  # h264 over the default HEVC so the file plays anywhere, and --mask=black so the rounded corners
  # and the notch come out black instead of as an unmasked rectangular framebuffer.
  xcrun simctl io "$DEVICE" recordVideo --codec=h264 --mask=black --force "$OUT" &
  RECORDER_PID=$!
  sleep 2
  START_EPOCH=$(date +%s)
}

stop_recording() {
  [ -n "$RECORDER_PID" ] || return 0
  sleep 1
  # SIGINT, not SIGKILL: simctl finalizes the movie on interrupt, and a killed recorder leaves an
  # unplayable file.
  kill -INT "$RECORDER_PID" 2> /dev/null || true
  wait "$RECORDER_PID" 2> /dev/null || true
  RECORDER_PID=""
  echo "==> Wrote $OUT"
  echo "    Captions: $CAPTIONS"
}

# --- the tour ------------------------------------------------------------------------------------

# Everything after sign-in. Both recorders call this.
tour() {
  beat "The service list — every service in the active workspace" 3

  beat "Search narrows it down" 1
  tap "${LIST_SEARCH[@]}"
  sleep 1
  swift "$REPO_ROOT/Scripts/sim-input.swift" type "$SERVICE" > /dev/null
  sleep 2.5
  tap "${LIST_FIRST_RESULT[@]}"
  beat "Service detail: current deploy first, then the configuration facts worth knowing on call" 4

  tap "${DETAIL_ACTIONS[@]}"
  beat "The action set is computed per service — this one can deploy, restart, suspend, scale" 4
  tap "${SAFE_DISMISS[@]}"
  sleep 1

  scroll_to_bottom
  beat "Below the configuration, the drill-downs" 2

  tap "${DETAIL_DEPLOYS[@]}"
  beat "Deploy history, newest first, paging as you scroll" 3
  tap "${DEPLOY_FIRST_ROW[@]}"
  beat "One deploy: status, trigger, timing, and the commit that shipped" 4
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DETAIL_METRICS[@]}"
  beat "Metrics, charted against the plan's limits" 5
  tap "${METRICS_24H[@]}"
  beat "Same charts over 24 hours" 4
  scroll_to_bottom
  beat "Chart set is chosen per service type" 3
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DETAIL_EVENTS[@]}"
  beat "Events: what Render did to this service, and when" 4
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DETAIL_LOGS[@]}"
  beat "Logs, newest first, severity down the left edge" 5
  tap "${LOGS_FILTER[@]}"
  # Long enough for /logs/values to answer: the sheet opens on "Loading values…" placeholders, and
  # the point of the beat is the vocabulary it fills them with.
  beat "Filtering is server-side, and the vocabulary comes from what this service actually emits" 8
  # Cancel, not Apply — leaving a filter applied would empty the list the next beat is about.
  tap "${LOGS_FILTER_CANCEL[@]}"
  sleep 1.5
  tap "${LOGS_MENU[@]}"
  sleep 1.5
  tap "${LOGS_LIVE_TAIL[@]}"
  beat "A live tail over a WebSocket — lines arrive as they happen" 10
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${LIST_CLEAR_SEARCH[@]}"
  beat "Back to the list" 3
}
