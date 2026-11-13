#!/bin/bash
# Re-vendor the Render OpenAPI spec and regenerate the Swift client.
#
# Structurally a port of render-agent/scripts/generate.sh, swapping `go generate` for
# swift-openapi-generator. Both the flattened spec and the generated Swift are committed, so
# running this turns an upstream spec change into two reviewable diffs rather than a surprise
# build break. See PLAN.md for why.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$REPO_ROOT/Packages/RenderAPI"
SPEC="$PKG/openapi.json"
CONFIG="$PKG/openapi-generator-config.yaml"
OUT="$PKG/Sources/RenderAPI/Generated"
SPEC_URL="https://api-docs.render.com/openapi/render-public-api-1.json"

echo "==> Downloading Render spec"
curl -sSfL -o "$SPEC" "$SPEC_URL"

echo "==> Pretty-printing"
jq . "$SPEC" > "$SPEC.tmp" && mv "$SPEC.tmp" "$SPEC"

echo "==> Flattening intra-path \$ref pointers"
# Mandatory, not cosmetic: OpenAPIKit only resolves refs into #/components/..., and the raw
# spec has ~250 refs into #/paths/... Without this the generator fails outright.
python3 "$REPO_ROOT/Scripts/flatten-path-refs.py" "$SPEC"

remaining=$(grep -c '#/paths/' "$SPEC" || true)
if [ "$remaining" != "0" ]; then
  echo "!!! $remaining unresolved #/paths/ refs remain — generation will fail" >&2
  exit 1
fi

echo "==> Relaxing required for fields the API returns as null"
# The spec marks some fields required + non-nullable that the live API sends as null; without
# this the generated strict decoder rejects real responses. See the script for the field list.
python3 "$REPO_ROOT/Scripts/relax-nullable.py" "$SPEC"

echo "==> Widening enums the live API overruns"
# An enum value the spec doesn't list fails the whole response decode, and Render still runs
# resources on plans and versions it no longer documents. See the script for the value list.
python3 "$REPO_ROOT/Scripts/widen-enums.py" "$SPEC"

echo "==> Ordering undiscriminated oneOf members"
# service.serviceDetails has no discriminator, so the generated decoder takes the first member that
# decodes — which makes the spec's ordering decide correctness. See the script for the one pair
# (cron job vs background worker) where the spec's order is wrong.
python3 "$REPO_ROOT/Scripts/order-oneof.py" "$SPEC"

echo "==> Giving GET /env-groups its cursor envelope"
# The spec says the response is a bare array of envGroupMeta; the live API returns the usual
# {envGroup, cursor} envelope, whose shape the strict decoder rejects outright. See the script.
python3 "$REPO_ROOT/Scripts/envelope-env-groups.py" "$SPEC"

echo "==> Making event details free-form"
# `details` is an undiscriminated oneOf whose empty members match everything, so the generated
# decoder silently drops every field. A free-form object keeps them. See the script.
python3 "$REPO_ROOT/Scripts/freeform-event-details.py" "$SPEC"

echo "==> Correcting the metrics endpoints the spec misdescribes"
# bandwidth-sources returns the ordinary time-series array, not the envelope the spec describes;
# the filter endpoints reject parameters the spec declares (and require one it deprecates). See
# the script.
python3 "$REPO_ROOT/Scripts/metrics-quirks.py" "$SPEC"

echo "==> Fixing numeric query parameter types"
# The spec types every numeric query parameter as `number`, which the generator maps to Double or
# Float — and Render accepts neither serialization: it rejects `resolutionSeconds=60.0` outright, and
# a Float quantile prints as 0.949999988079071 rather than 0.95. See the script.
python3 "$REPO_ROOT/Scripts/number-params.py" "$SPEC"

echo "==> Generating Swift client"
# Invoked as a plain executable rather than as a build-tool plugin, so that the generated
# sources can be committed and the spec kept outside Sources/. Also avoids Xcode's
# per-checkout "Trust & Enable" plugin prompt.
cd "$PKG"
rm -rf "$OUT"
mkdir -p "$OUT"
swift run -q swift-openapi-generator generate "$SPEC" \
  --config "$CONFIG" \
  --output-directory "$OUT"

# The generator always emits all three files; Server.swift is empty because we only request
# types+client. Drop it rather than committing a stub.
rm -f "$OUT/Server.swift"

echo "==> Generated:"
wc -l "$OUT"/*.swift

echo "==> Done. Review with: git diff --stat Packages/RenderAPI"
