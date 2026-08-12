#!/bin/bash
# Live smoke test against the real Render API using the key in .env.
#
# Read-only: it only issues GETs (owners, services, deploys, events, logs) so it can be run safely
# against a real account. Nothing here triggers a deploy, restart, or any other lifecycle action —
# those are smoke-tested by hand from the app, deliberately.
#
#   Scripts/smoke.sh            # owners + services, then the per-phase payload checks
#   Scripts/smoke.sh srv-xxxx   # the same checks against one specific service
#
# The key is read from .env (gitignored), never passed on the command line (so it stays out of the
# shell history and process list of other users).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_ROOT/.env"
API="https://api.render.com/v1"

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

auth=(-H "Authorization: Bearer $RENDER_API_KEY" -H "Accept: application/json")

echo "==> GET /owners"
owners=$(curl -fsS "${auth[@]}" "$API/owners?limit=100")
echo "$owners" | jq -r '.[] | "  \(.owner.type)\t\(.owner.name)\t(\(.owner.id))"'

first_owner=$(echo "$owners" | jq -r '.[0].owner.id')
echo "==> GET /services?ownerId=$first_owner (first 20)"
services=$(curl -fsS "${auth[@]}" "$API/services?ownerId=$first_owner&limit=20&includePreviews=false")
echo "$services" | jq -r '.[] | "  \(.service.type)\t\(.service.suspended)\t\(.service.name)"'

# --- Phase 2: the payloads behind the detail screen ------------------------------------------------

service_id="${1:-$(echo "$services" | jq -r '.[0].service.id')}"
if [ -z "$service_id" ] || [ "$service_id" = "null" ]; then
  echo "==> No services to inspect; skipping Phase 2 checks."
  exit 0
fi

echo "==> GET /services/$service_id"
service=$(curl -fsS "${auth[@]}" "$API/services/$service_id")
echo "$service" | jq -r '"  \(.type)\t\(.name)\tsuspended=\(.suspended)\tautoDeploy=\(.autoDeploy)"'
echo "  serviceDetails keys: $(echo "$service" | jq -r '.serviceDetails | keys | join(", ")')"

echo "==> GET /services/$service_id/deploys (first 5)"
curl -fsS "${auth[@]}" "$API/services/$service_id/deploys?limit=5" \
  | jq -r '.[] | "  \(.deploy.status // "?")\t\(.deploy.trigger // "?")\t\(.deploy.id)\t\((.deploy.commit.message // .deploy.image.ref // "") | split("\n")[0])"'

echo "==> GET /services/$service_id/events (first 5)"
curl -fsS "${auth[@]}" "$API/services/$service_id/events?limit=5" \
  | jq -r '.[] | "  \(.event.timestamp)\t\(.event.type)\tdetails: \(.event.details | keys | join(","))"'

# Two spec-vs-reality checks that decide whether the detail screen can trust what it decodes. Both
# are assumptions baked into the app; this is how you find out they stopped holding.
echo "==> Spec assumptions"
# 1. Scripts/order-oneof.py assumes a cron job may include numInstances (which is why cronJobDetails
#    must be tried before backgroundWorkerDetails) and that a worker never includes schedule.
cron_id=$(echo "$services" | jq -r '[.[] | select(.service.type == "cron_job")][0].service.id // empty')
if [ -n "$cron_id" ]; then
  cron_keys=$(curl -fsS "${auth[@]}" "$API/services/$cron_id" | jq -r '.serviceDetails | keys | join(",")')
  echo "  cron_job serviceDetails: $cron_keys"
  case "$cron_keys" in
    *schedule*) ;;
    *) echo "  !!! a cron job's details have no 'schedule' — ServiceDetails would misreport it" ;;
  esac
else
  echo "  (no cron job in this workspace — cron-vs-worker ordering unverified against live data)"
fi
# 2. The events envelope is documented to carry a cursor but never defines the property, so
#    ServiceEventsStore pages by endTime instead. If a cursor ever appears, switch back.
event_keys=$(curl -fsS "${auth[@]}" "$API/services/$service_id/events?limit=1" | jq -r '.[0] | keys | join(",")')
echo "  events envelope keys: ${event_keys:-none}"
case "$event_keys" in
  *cursor*) echo "  !!! events now return a cursor — ServiceEventsStore can use CursorPaginator" ;;
esac

# --- Phase 3: logs -------------------------------------------------------------------------------

echo "==> GET /logs?resource=$service_id (last 5)"
logs=$(curl -fsS "${auth[@]}" "$API/logs?ownerId=$first_owner&resource=$service_id&direction=backward&limit=5")
echo "$logs" | jq -r '.logs[] | "  \(.timestamp)\t\((.labels[] | select(.name == "level") | .value) // "-")\t\(.message | split("\n")[0][0:100])"'
echo "  hasMore=$(echo "$logs" | jq -r .hasMore) nextStartTime=$(echo "$logs" | jq -r .nextStartTime) nextEndTime=$(echo "$logs" | jq -r .nextEndTime)"

# LogsStore pages on the window Render hands back rather than a cursor, so the response has to carry
# all three. A null in any of them would silently stop paging after the first page.
for field in hasMore nextStartTime nextEndTime; do
  if [ "$(echo "$logs" | jq -r ".$field")" = "null" ]; then
    echo "  !!! /logs returned null for $field — LogsStore cannot page"
  fi
done

echo "==> GET /logs/values (the filter sheet's vocabulary)"
for label in level type statusCode method instance host; do
  values=$(curl -fsS "${auth[@]}" "$API/logs/values?ownerId=$first_owner&resource=$service_id&label=$label" | jq -r 'join(", ")')
  echo "  $label: ${values:-(none)}"
done

# The one endpoint the generated client can't reach: a 101 upgrade, hand-written in LogStream.swift.
# curl speaks enough of the handshake to prove the URL, auth, and query shape are right.
echo "==> GET /logs/subscribe (WebSocket handshake)"
handshake=$(curl -sS -o /dev/null -D - \
  "${auth[@]}" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: $(head -c 16 /dev/urandom | base64)" \
  --max-time 10 \
  "$API/logs/subscribe?ownerId=$first_owner&resource=$service_id" 2>/dev/null | head -1 || true)
echo "  ${handshake:-no response}"
case "$handshake" in
  *101*) ;;
  *) echo "  !!! expected 101 Switching Protocols — LogStream's live tail will not connect" ;;
esac
