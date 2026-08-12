#!/bin/bash
# Live smoke test against the real Render API using the key in .env.
#
# Read-only: it only issues GETs (owners, services) so it can be run safely against a real account.
# Use it to confirm the app's list matches what the API returns for a phase's screens.
#
#   Scripts/smoke.sh            # summarize owners + services
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
curl -fsS "${auth[@]}" "$API/services?ownerId=$first_owner&limit=20" \
  | jq -r '.[] | "  \(.service.type)\t\(.service.suspended)\t\(.service.name)"'
