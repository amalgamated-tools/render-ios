#!/bin/bash
# Capture the README's screenshot set from a running simulator.
#
#   SERVICE=flask-hello-world Scripts/capture-screenshots.sh
#
# The thirteen images in docs/screenshots were originally captured by hand, which is why they had
# drifted a whole UI revision behind the app (they predate the Postgres and Key Value tabs). This
# drives the same tour walkthrough-lib.sh does and writes a PNG at each stop, so a refresh is one
# command — the same reason make-brand-assets.swift is committed rather than being a Photoshop
# session.
#
# It reuses walkthrough-lib.sh's tap coordinates, so there is exactly one place to fix when the
# layout moves. It does NOT reset the app: it expects you to be signed in already, because the
# whole point is to photograph real content.
#
# Like the walkthrough recorder, this shows **real data** — workspace name, service names, log
# lines, hostnames. Point it at an account you're willing to publish.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$REPO_ROOT/Scripts/walkthrough-lib.sh"

OUT_DIR="${OUT_DIR:-$REPO_ROOT/docs/screenshots}"
STATIC_SERVICE="${STATIC_SERVICE:-demo-site}"

find_device
mkdir -p "$OUT_DIR"

# simctl returns as soon as the PNG is written, but the frame it captures is whatever was on screen
# when the request landed — so a settle before each shot, not after.
shot() {
  sleep "${2:-1.5}"
  xcrun simctl io "$DEVICE" screenshot "$OUT_DIR/$1.png" > /dev/null 2>&1
  echo "  wrote $OUT_DIR/$1.png"
}

back() { tap "${NAV_BACK[@]}"; sleep 1.5; }

echo "==> Capturing from $SIMULATOR ($DEVICE)"
echo "    service: $SERVICE   static site: $STATIC_SERVICE"

# --- the list, and one service end to end --------------------------------------------------------
shot services-list 2

tap "${LIST_SEARCH[@]}"
sleep 1
swift "$REPO_ROOT/Scripts/sim-input.swift" type "$SERVICE" > /dev/null
sleep 2.5
tap "${LIST_FIRST_RESULT[@]}"
shot service-detail 3

tap "${DETAIL_ACTIONS[@]}"
shot actions-menu 2
tap "${SAFE_DISMISS[@]}"
sleep 1

scroll_to_bottom

tap "${DETAIL_DEPLOYS[@]}"
shot deploys 3
tap "${DEPLOY_FIRST_ROW[@]}"
shot deploy-detail 3
back
back

tap "${DETAIL_METRICS[@]}"
shot metrics 6
tap "${METRICS_24H[@]}"
sleep 4
# The HTTP charts sit below the resource ones; the same scroll the tour uses gets to them.
scroll_to_bottom
# Skipped by default. Render answers an error for HTTP Requests and HTTP Latency on free instance
# types, so on a free service this captures two "Couldn't load this metric" cards — which would
# directly contradict the README caption next to it, about requests grouped by status code and
# latency at p50/p95/p99. Set CAPTURE_HTTP=1 when pointing this at a paid service.
[ "${CAPTURE_HTTP:-0}" = "1" ] && shot metrics-http 3
back

tap "${DETAIL_EVENTS[@]}"
shot events 3
back

tap "${DETAIL_LOGS[@]}"
shot logs 5
tap "${LOGS_FILTER[@]}"
# /logs/values has to answer before the sheet is worth photographing — it opens on five "Loading
# values…" rows, and a shot of those says the opposite of what the caption beside it claims. 8s was
# not enough on a cold service; 25 is.
shot logs-filter 25
tap "${LOGS_FILTER_CANCEL[@]}"
sleep 1.5
tap "${LOGS_MENU[@]}"
sleep 1.5
tap "${LOGS_LIVE_TAIL[@]}"
shot logs-live 10
back
back
tap "${LIST_CLEAR_SEARCH[@]}"
sleep 1.5

# --- a static site, for the chart set that differs -----------------------------------------------
tap "${LIST_SEARCH[@]}"
sleep 1
swift "$REPO_ROOT/Scripts/sim-input.swift" type "$STATIC_SERVICE" > /dev/null
sleep 2.5
tap "${LIST_FIRST_RESULT[@]}"
sleep 3
scroll_to_bottom
# The one place the two service types can't share a tap. A static site's drill-down card is TALLER,
# not shorter — it drops CPU and memory but gains Custom Domains, Redirects & Rewrites, and Headers,
# so ten rows against a web service's eight. Scrolled to the bottom that pushes the block up by two
# rows, and DETAIL_METRICS lands on Environment. Measured off a live pass, like the rest.
STATIC_DETAIL_METRICS=(300 853)
tap "${STATIC_DETAIL_METRICS[@]}"
shot metrics-static-site 6
back
back
tap "${LIST_CLEAR_SEARCH[@]}"

echo "==> Done. onboarding.png is captured separately — it needs a signed-out app."
