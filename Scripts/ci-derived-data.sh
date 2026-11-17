#!/bin/bash
# Print the DerivedData path CI should build into, wiping it first if the generated API client has
# changed since it was last used.
#
# Why: the self-hosted runner keeps DerivedData between runs, and after a PR regenerated
# Packages/RenderAPI/Sources/RenderAPI/Generated, App tests compiled the app against the *previous*
# RenderAPI module ("cannot convert value of type '...EventFilterPayload' to expected argument type
# '[String]'") while the same commit built and tested cleanly anywhere else. It happened on #58 and
# #64; a re-run fixed it each time. Starting clean whenever the generated client changes keeps every
# other run incremental.
#
# Usage: DD=$(Scripts/ci-derived-data.sh <name>)  # <name> separates jobs, e.g. "test" or "build"
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:?usage: ci-derived-data.sh <name>}"
# Outside the checkout: actions/checkout cleans ignored files, which would make every run cold.
BASE="${CI_DERIVED_DATA_ROOT:-$HOME/Library/Caches/render-ios-ci}"
DD="$BASE/$NAME"
STAMP="$DD/.renderapi-generated.sha"

HASH=$(cd "$REPO_ROOT" && cat Packages/RenderAPI/openapi.json Packages/RenderAPI/Sources/RenderAPI/Generated/*.swift | shasum -a 256 | cut -d' ' -f1)

if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$HASH" ]; then
  echo "==> Generated RenderAPI client changed: starting $DD clean" >&2
  rm -rf "$DD"
  mkdir -p "$DD"
  echo "$HASH" > "$STAMP"
fi

echo "$DD"
