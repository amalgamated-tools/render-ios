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
# --http1.1 is required, not stylistic: a WebSocket upgrade is an HTTP/1.1 mechanism, and curl
# negotiating HTTP/2 gets a 426 that looks exactly like a broken endpoint. URLSessionWebSocketTask
# speaks 1.1 for the handshake itself, so the app was never affected.
handshake=$(curl -sS --http1.1 -o /dev/null -D - \
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

# --- Phase 4: metrics ----------------------------------------------------------------------------

# The window the app's shortest range asks for.
metrics_start=$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)
metrics_end=$(date -u +%Y-%m-%dT%H:%M:%SZ)
metrics_window="startTime=$metrics_start&endTime=$metrics_end&resource=$service_id"

echo "==> GET /metrics/* (last hour, 60s resolution)"
# Every one of these decodes into the single MetricSeries type, so what matters per endpoint is the
# series count, the unit, and whether any points came back at all.
for metric in cpu cpu-limit cpu-target memory memory-limit memory-target \
              http-requests http-latency instance-count disk-usage disk-capacity; do
  # /metrics/bandwidth is handled separately: it's the one series endpoint that declares no
  # resolutionSeconds, and sending one anyway is a 400.
  body=$(curl -fsS "${auth[@]}" "$API/metrics/$metric?$metrics_window&resolutionSeconds=60" 2>/dev/null || echo '[]')
  printf '  %-16s series=%s unit=%s points=%s\n' \
    "$metric" \
    "$(echo "$body" | jq -r 'length')" \
    "$(echo "$body" | jq -r '[.[].unit] | unique | join(",") | if . == "" then "-" else . end')" \
    "$(echo "$body" | jq -r '[.[].values | length] | add // 0')"

  # MetricUnit reads the unit off the series rather than hard-coding one per endpoint. The Phase 0
  # survey found the *datapoint* unit missing from the spec; if the series-level one ever goes the
  # same way, every axis label silently loses its unit.
  if [ "$(echo "$body" | jq -r 'length')" != "0" ] && [ "$(echo "$body" | jq -r '[.[] | has("unit")] | all')" != "true" ]; then
    echo "  !!! $metric returned a series with no unit — MetricUnit has nothing to read"
  fi
done

echo "==> GET /metrics/bandwidth (no resolutionSeconds — the endpoint doesn't declare it)"
bandwidth=$(curl -fsS "${auth[@]}" "$API/metrics/bandwidth?$metrics_window" 2>/dev/null || echo '[]')
printf '  bandwidth        series=%s unit=%s points=%s\n' \
  "$(echo "$bandwidth" | jq -r 'length')" \
  "$(echo "$bandwidth" | jq -r '[.[].unit] | unique | join(",") | if . == "" then "-" else . end')" \
  "$(echo "$bandwidth" | jq -r '[.[].values | length] | add // 0')"

# Scripts/number-params.py drops `format: float` because it made the generator send
# quantile=0.949999988079071 instead of 0.95. This is the live check on whether that mattered. As of the
# Phase 4 live pass the two agree exactly, so Render tolerates the widened value — keep the check, since
# a change here would silently mean requesting a quantile nobody asked for.
echo "==> GET /metrics/http-latency — quantile literal fidelity"
for q in 0.95 0.949999988079071; do
  printf '  quantile=%-20s points=%s\n' "$q" \
    "$(curl -fsS "${auth[@]}" "$API/metrics/http-latency?$metrics_window&resolutionSeconds=60&quantile=$q" 2>/dev/null \
       | jq -r '[.[].values | length] | add // 0')"
done

# --- Phase 5: service config (read-only) -----------------------------------------------------------

# Values are secrets, so nothing here prints one: only key names, counts, and shapes. The app's own
# write paths (PUT/DELETE per key) are exercised by hand from the simulator, deliberately — a smoke
# script that mutates a real service would redeploy it.

echo "==> GET /services/$service_id/env-vars"
env_vars=$(curl -fsS "${auth[@]}" "$API/services/$service_id/env-vars?limit=100")
echo "  count=$(echo "$env_vars" | jq -r 'length')  keys: $(echo "$env_vars" | jq -r '[.[].envVar.key] | join(", ")')"

# EnvVarEntry reads both fields unconditionally; the spec marks them required, and a null value would
# fail the decode before the screen ever sees it.
if [ "$(echo "$env_vars" | jq -r '[.[].envVar | has("key") and has("value")] | all')" != "true" ]; then
  echo "  !!! an envVar came back without key/value — EnvVarEntry won't decode it"
fi

echo "==> GET /services/$service_id/secret-files"
secret_files=$(curl -fsS "${auth[@]}" "$API/services/$service_id/secret-files?limit=100")
echo "  count=$(echo "$secret_files" | jq -r 'length')  names: $(echo "$secret_files" | jq -r '[.[].secretFile.name] | join(", ")')"

# The list endpoint returning contents is what lets the editor open a file without a second request.
# If Render ever stops sending it, `content` is required in the spec and the whole list stops
# decoding — which is the failure this line is here to catch early.
if [ "$(echo "$secret_files" | jq -r 'length')" != "0" ]; then
  echo "  contents present in list: $(echo "$secret_files" | jq -r '[.[].secretFile | has("content")] | all')"
  echo "  sizes: $(echo "$secret_files" | jq -r '[.[].secretFile | "\(.name)=\(.content | length)B"] | join(", ")')"
fi

# --- Phase 5b: env groups, custom domains, headers, routes (read-only) -----------------------------

echo "==> GET /env-groups?ownerId=$first_owner"
env_groups=$(curl -fsS "${auth[@]}" "$API/env-groups?ownerId=$first_owner&limit=100")
echo "  count=$(echo "$env_groups" | jq -r 'length')"
echo "$env_groups" | jq -r '.[] | "  \(.envGroup.name)\tlinks=\(.envGroup.serviceLinks | length)\t(\(.envGroup.id))"'

# The live API wraps each group in the usual {envGroup, cursor} envelope, but the *spec* declares a bare
# array of envGroupMeta — which the strict decoder rejects outright, so the list wouldn't load at all
# until Scripts/envelope-env-groups.py patched the spec to match. This guards the patch: if Render ever
# ships the shape it documents, the envelope disappears and the patch has to go with it.
if [ "$(echo "$env_groups" | jq -r '[.[] | has("envGroup")] | all')" != "true" ]; then
  echo "  !!! /env-groups no longer wraps groups in a cursor envelope — drop Scripts/envelope-env-groups.py"
fi
# serviceLinks is the only record of which services use a group; there is no service-side endpoint.
if [ "$(echo "$env_groups" | jq -r '[.[] | .envGroup | has("serviceLinks")] | all')" != "true" ]; then
  echo "  !!! an env group came back without serviceLinks — the linked-services screens depend on it"
fi

group_id=$(echo "$env_groups" | jq -r '.[0].envGroup.id // empty')
if [ -n "$group_id" ]; then
  echo "==> GET /env-groups/$group_id"
  group=$(curl -fsS "${auth[@]}" "$API/env-groups/$group_id")
  # Both config screens for a group read out of *this* payload — there is no per-group list endpoint —
  # so their loading breaks entirely if these two fields stop arriving inline.
  echo "  envVars inline: $(echo "$group" | jq -r 'has("envVars")')  secretFiles inline: $(echo "$group" | jq -r 'has("secretFiles")')"
  echo "  var count=$(echo "$group" | jq -r '.envVars | length')  file count=$(echo "$group" | jq -r '.secretFiles | length')"
  echo "  keys: $(echo "$group" | jq -r '[.envVars[].key] | join(", ")')"
fi

echo "==> GET /services/$service_id/custom-domains"
# A wrong service type fails these three. The spec advertises 406; the live API answers **400** with
# "invalid service type. Only static sites have routes", which is what ServiceConfigCatalog gates on —
# so a failure here is reported rather than fatal.
domains=$(curl -sS -w '\n%{http_code}' "${auth[@]}" "$API/services/$service_id/custom-domains?limit=100")
domains_code=$(echo "$domains" | tail -1)
domains_body=$(echo "$domains" | sed '$d')
if [ "$domains_code" = "200" ]; then
  echo "  count=$(echo "$domains_body" | jq -r 'length')"
  echo "$domains_body" | jq -r '.[] | "  \(.customDomain.verificationStatus)\t\(.customDomain.domainType)\t\(.customDomain.name)\tredirectFor=\(.customDomain.redirectForName)"'
else
  echo "  HTTP $domains_code (400/406 = not available for this service type, which the app gates on)"
fi

echo "==> GET /services/$service_id/routes"
routes=$(curl -sS -w '\n%{http_code}' "${auth[@]}" "$API/services/$service_id/routes?limit=100")
routes_code=$(echo "$routes" | tail -1)
if [ "$routes_code" = "200" ]; then
  echo "$routes" | sed '$d' | jq -r '.[] | "  \(.route.priority)\t\(.route.type)\t\(.route.source) -> \(.route.destination)"'
else
  echo "  HTTP $routes_code"
fi

echo "==> GET /services/$service_id/headers"
headers=$(curl -sS -w '\n%{http_code}' "${auth[@]}" "$API/services/$service_id/headers?limit=100")
headers_code=$(echo "$headers" | tail -1)
if [ "$headers_code" = "200" ]; then
  echo "$headers" | sed '$d' | jq -r '.[] | "  \(.header.path)\t\(.header.name): \(.header.value)"'
else
  echo "  HTTP $headers_code"
fi

# --- Phase 5c: datastores (read-only) --------------------------------------------------------------

echo "==> GET /postgres?ownerId=$first_owner"
postgres_list=$(curl -fsS "${auth[@]}" "$API/postgres?ownerId=$first_owner&includeReplicas=true&limit=100")
echo "  count=$(echo "$postgres_list" | jq -r 'length')"
echo "$postgres_list" | jq -r '.[] | "  \(.postgres.status)\t\(.postgres.plan)\t\(.postgres.role)\t\(.postgres.name)\t(\(.postgres.id))"'

postgres_id=$(echo "$postgres_list" | jq -r '.[0].postgres.id // empty')
if [ -n "$postgres_id" ]; then
  echo "==> GET /postgres/$postgres_id"
  pg=$(curl -fsS "${auth[@]}" "$API/postgres/$postgres_id")
  echo "  $(echo "$pg" | jq -r '"\(.name)\tstatus=\(.status)\tversion=\(.version)\tha=\(.highAvailabilityEnabled)\tdiskSizeGB=\(.diskSizeGB // "none")"')"

  echo "==> GET /postgres/$postgres_id/connection-info"
  # Assert the shape without printing the body — every field is a credential.
  pg_conn_code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" "$API/postgres/$postgres_id/connection-info")
  echo "  HTTP $pg_conn_code (body suppressed: credentials)"
fi

echo "==> GET /key-value?ownerId=$first_owner"
kv_list=$(curl -fsS "${auth[@]}" "$API/key-value?ownerId=$first_owner&limit=100")
echo "  count=$(echo "$kv_list" | jq -r 'length')"
echo "$kv_list" | jq -r '.[] | "  \(.keyValue.status)\t\(.keyValue.plan)\t\(.keyValue.name)\t(\(.keyValue.id))"'

kv_id=$(echo "$kv_list" | jq -r '.[0].keyValue.id // empty')
if [ -n "$kv_id" ]; then
  echo "==> GET /key-value/$kv_id"
  kv=$(curl -fsS "${auth[@]}" "$API/key-value/$kv_id")
  echo "  $(echo "$kv" | jq -r '"\(.name)\tstatus=\(.status)\tversion=\(.version)\tpolicy=\(.options.maxmemoryPolicy // "unset")"')"
  # The detail payload documents no dashboardUrl, which is why the app carries the list's copy into
  # the detail screen. If it ever starts arriving, that plumbing can go.
  if [ "$(echo "$kv" | jq -r 'has("dashboardUrl")')" = "true" ]; then
    echo "  !!! /key-value/{id} now returns dashboardUrl — KeyValueDetailView no longer needs it passed in"
  fi

  echo "==> GET /key-value/$kv_id/connection-info"
  kv_conn_code=$(curl -sS -o /dev/null -w '%{http_code}' "${auth[@]}" "$API/key-value/$kv_id/connection-info")
  echo "  HTTP $kv_conn_code (body suppressed: credentials)"
fi
