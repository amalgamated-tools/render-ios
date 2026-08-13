#!/bin/bash
# Shared machinery for the walkthrough recorders: device lookup, a deterministic reset, screen
# recording, captions, and the post-sign-in tour itself.
#
# Sourced by record-walkthrough.sh (API key) and record-walkthrough-oauth.sh (device flow). The two
# differ only in how they get past onboarding; everything after that is `tour` below.
#
# Coordinates are in the pixel space of `xcrun simctl io <device> screenshot` on an **iPhone 17 Pro**
# (1206x2622), which is the same space sim-input.swift takes. They were read off screenshots during a
# live pass; a different device size needs a new pass.
#
# **Nothing in the tour writes.** Every tap either navigates or opens something that is cancelled
# again. The two editing surfaces it shows — the add-variable sheet and the account menu — are opened
# for the picture and dismissed without saving, and the datastore action menus are deliberately not
# opened at all: on Postgres and Key Value the destructive item renders directly under the toolbar,
# close enough that a mistimed dismiss tap could fire it. See `datastore_tour`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIMULATOR="${SIMULATOR:-iPhone 17 Pro}"
# The web service the first half tours, and the static site the second half needs: redirect, rewrite
# and header rules exist only on a static site, so one service can't show the whole drill-down list.
SERVICE="${SERVICE:-flask-hello-world}"
STATIC_SERVICE="${STATIC_SERVICE:-demo-site}"
OUT="${OUT:-$REPO_ROOT/docs/walkthrough.mov}"
BUNDLE_ID="com.veverkap.RenderiOS"
# Matches run-simulator.sh, which does the build this script leans on.
APP="$REPO_ROOT/build/DerivedData/Build/Products/Debug-iphonesimulator/RenderiOS.app"

# --- taps, in screenshot pixels ------------------------------------------------------------------
ONBOARD_SIGNIN=(601 1093)     # "Sign in with Render"
ONBOARD_APIKEY=(280 1267)     # "Use an API key instead" — expanding it focuses the field
ONBOARD_CONTINUE=(601 1586)
DEVICE_AUTH_OPEN=(641 1589)   # "Open render.com to approve", on the device-flow waiting screen
LIST_SEARCH=(346 417)
LIST_FIRST_RESULT=(406 447)   # first row once the search field is active
LIST_SCOPE=(601 252)          # the workspace/project picker, in the title slot
LIST_ACCOUNT=(916 252)
LIST_SIGNOUT=(714 278)
NAV_BACK=(113 252)
DETAIL_ACTIONS=(1087 252)
# The tab bar. Every tab carries the same scope picker and account menu.
TAB_SERVICES=(220 2495)
TAB_POSTGRES=(473 2495)
TAB_KEYVALUE=(728 2495)
TAB_ENVGROUPS=(983 2495)
# The drill-down rows, with the detail screen scrolled to the bottom. The card is bottom-anchored,
# so a service type with more rows pushes the whole ladder *up* by a fixed 156px per extra row
# rather than shifting each row independently — which is why the static-site set below is the same
# ladder offset by two, and why `scroll_to_bottom` overshoots on purpose.
DETAIL_DEPLOYS=(307 853)
DETAIL_LOGS=(270 1009)
DETAIL_METRICS=(300 1165)
DETAIL_EVENTS=(291 1321)
DETAIL_ENV=(300 1476)
DETAIL_SECRET_FILES=(300 1632)
DETAIL_ENV_GROUPS=(300 1788)
DETAIL_DOMAINS=(300 1944)
# A static site has two rows a web service doesn't, so its last three sit two rows higher.
STATIC_DOMAINS=(300 1632)
STATIC_ROUTES=(300 1788)
STATIC_HEADERS=(300 1944)
ENV_ADD=(1090 252)            # "+" on the Environment screen — opens the add sheet
ENV_FIRST_REVEAL=(1078 482)   # the eye on the first variable row
SHEET_CANCEL=(176 300)        # "Cancel" on a presented sheet, which covers the whole screen
# The datastore tabs, whose list and detail layouts are shared between Postgres and Key Value.
DATASTORE_FIRST_ROW=(600 642)
DATASTORE_LOGS=(300 1788)
DATASTORE_METRICS=(300 1944)
# The Env Groups tab. Its list has no leading divider, so the first row sits slightly higher than a
# service or datastore row.
EG_FIRST_ROW=(600 626)
EG_VARS=(468 531)
EG_FILES=(348 687)
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
#
# The settle at the end is not padding. A tap that arrives while the scroll view is still decelerating
# is spent stopping it rather than on the row underneath, and the tour has no way to notice: the next
# tap is a Back that pops a screen that was never pushed, and everything after it lands somewhere
# arbitrary. A whole leg of the tour went missing that way, from one second of settle instead of two.
scroll_to_bottom() {
  drag 601 2100 601 900
  sleep 0.6
  drag 601 2100 601 900
  sleep 2
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
  sleep 3
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
  # Stamped here rather than after the settle sleep below, so that beat 0 and video second 0 name the
  # same instant. Two seconds of head start had been quietly added to every caption.
  START_EPOCH=$(date +%s)
  # simctl needs a moment before the first frame lands; taps during it record as a still frame.
  sleep 2
}

stop_recording() {
  [ -n "$RECORDER_PID" ] || return 0
  sleep 1
  # SIGINT, not SIGKILL: simctl finalizes the movie on interrupt, and a killed recorder leaves an
  # unplayable file.
  kill -INT "$RECORDER_PID" 2> /dev/null || true
  wait "$RECORDER_PID" 2> /dev/null || true
  RECORDER_PID=""
  # How long the tour actually took, so beats-to-srt.py can correct for the recorder's clock.
  #
  # simctl timestamps frames by when the screen *changed* and never pads the gaps — recording a still
  # simulator for twenty seconds writes a 0.07-second movie. So the movie is always shorter than the
  # tour, by the total of every moment the screen sat still, and cues stamped in wall seconds run
  # late. Writing both endpoints down is what lets the SRT be scaled instead of guessed at.
  printf '# wall %d\n' "$(( $(date +%s) - START_EPOCH ))" >> "$CAPTIONS"
  echo "==> Wrote $OUT"
  echo "    Captions: $CAPTIONS"
}

# --- the tour ------------------------------------------------------------------------------------

# Everything after sign-in. Both recorders call this.
#
# Reads as one pass through the app: the list and one web service in depth, then the screens that only
# a static site has, then the two datastore tabs, then env groups, then out. Split into the functions
# below so a beat can be moved without re-reading two hundred lines.
tour() {
  beat "The service list — every service in the active workspace" 3

  tap "${LIST_SCOPE[@]}"
  beat "Scope is a workspace and, inside it, a project — every tab agrees about it" 5
  tap "${SAFE_DISMISS[@]}"
  sleep 1.5

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
  # One back, not two: this leaves the detail screen on screen and still scrolled to the bottom,
  # which is where `config_tour` expects to start. Returning to the list here — as this did before
  # the configuration screens existed — silently aimed every later tap at the wrong screen.
  tap "${NAV_BACK[@]}"
  sleep 1.5

  config_tour
  tap "${LIST_CLEAR_SEARCH[@]}"
  sleep 2
  static_site_tour
  datastore_tour "${TAB_POSTGRES[@]}" "Postgres" \
    "Every managed database in the workspace, with the plan and the version each is actually on"
  datastore_tour "${TAB_KEYVALUE[@]}" "Key Value" \
    "The same screen for Key Value: Valkey version, eviction policy, persistence"
  env_groups_tour
  sign_out_tour
}

# The four configuration screens hanging off a service, all of which read *and* write. Reached from
# the detail screen still scrolled to the bottom, which is where `tour` leaves it.
config_tour() {
  tap "${DETAIL_ENV[@]}"
  beat "Environment variables — masked by default, because this screen gets shown in standups" 5
  tap "${ENV_FIRST_REVEAL[@]}"
  beat "Revealing is per value, and resets the moment you navigate away" 4
  tap "${ENV_ADD[@]}"
  # The sheet animates in; cancelling too early lands the tap on the screen behind it.
  beat "Edits happen in a sheet with an explicit Save — nothing saves as you type" 5
  tap "${SHEET_CANCEL[@]}"
  sleep 2
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DETAIL_SECRET_FILES[@]}"
  beat "Secret files, mounted into the service at build and run time — masked on the same rule" 5
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DETAIL_ENV_GROUPS[@]}"
  beat "What this service inherits from a group, which its own variable list deliberately omits" 5
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DETAIL_DOMAINS[@]}"
  beat "Custom domains, with the verification state Render reports for each" 4
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${NAV_BACK[@]}"
  sleep 1.5
}

# Redirects, rewrites and headers are properties of Render's static-site CDN, not of the HTTP path in
# front of a service — asking a web service for its routes answers 400 — so the app withholds those
# rows everywhere else, and the tour needs a second service to show them at all.
static_site_tour() {
  beat "Which drill-downs exist depends on the service type" 2
  tap "${LIST_SEARCH[@]}"
  sleep 1
  swift "$REPO_ROOT/Scripts/sim-input.swift" type "$STATIC_SERVICE" > /dev/null
  sleep 2.5
  tap "${LIST_FIRST_RESULT[@]}"
  sleep 5
  scroll_to_bottom
  beat "A static site has two the web service didn't: it sits behind Render's CDN" 4

  tap "${STATIC_ROUTES[@]}"
  beat "Redirects and rewrites, in the priority order Render evaluates them" 5
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${STATIC_HEADERS[@]}"
  beat "Response headers, each scoped to a path pattern" 5
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${STATIC_DOMAINS[@]}"
  beat "And the domains it answers on" 4
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${LIST_CLEAR_SEARCH[@]}"
  sleep 2
}

# Postgres and Key Value. One function for both: the list and detail layouts are the same screen with
# a different catalog behind it, which is the point the beats make.
#
# The actions menu is **not** opened here, unlike on a service. On these two screens the menu is short
# enough that its destructive item renders directly under the toolbar, and a dismiss tap that landed a
# few pixels off would suspend a real database. The narration says what the menu holds instead.
datastore_tour() {
  local tab_x="$1" tab_y="$2" label="$3" caption="$4"
  tap "$tab_x" "$tab_y"
  sleep 4
  beat "$caption" 4
  tap "${DATASTORE_FIRST_ROW[@]}"
  beat "Status, then the configuration, then the connection strings — masked, like every secret" 6
  beat "Suspend and resume live in the toolbar menu, each behind a confirmation" 3
  scroll_to_bottom

  tap "${DATASTORE_METRICS[@]}"
  beat "$label metrics: the charts Render collects for this kind of instance" 6
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${DATASTORE_LOGS[@]}"
  beat "And its logs, on the same screen the services use" 5
  tap "${NAV_BACK[@]}"
  sleep 1.5
  tap "${NAV_BACK[@]}"
  sleep 2
}

# Env groups are the one resource that belongs to the workspace rather than to a service, which is why
# they get a tab rather than a drill-down.
env_groups_tour() {
  tap "${TAB_ENVGROUPS[@]}"
  sleep 4
  beat "Env groups belong to the workspace, not to a project or a service" 4
  tap "${EG_FIRST_ROW[@]}"
  beat "A group is variables, files, and the services they reach" 4

  tap "${EG_VARS[@]}"
  beat "The variables, masked on the same rule as a service's own" 5
  tap "${NAV_BACK[@]}"
  sleep 1.5

  tap "${EG_FILES[@]}"
  beat "And its secret files" 4
  tap "${NAV_BACK[@]}"
  sleep 1.5
  beat "Linking a service here is the same edit as linking a group from the service side" 4
  tap "${NAV_BACK[@]}"
  sleep 2
}

# Ends where it started: the service list, with the account menu open to show that signing out is one
# tap and that the key lives in the Keychain until you do.
sign_out_tour() {
  tap "${TAB_SERVICES[@]}"
  sleep 3
  tap "${LIST_ACCOUNT[@]}"
  beat "Signing out drops the credential from the Keychain" 4
  tap "${SAFE_DISMISS[@]}"
  beat "Back to the list" 3
}
