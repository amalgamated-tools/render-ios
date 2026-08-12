#!/usr/bin/env python3
"""Drop `format: float` from query parameters so the generator emits Double, not Float.

`swift-openapi-generator` maps `type: number, format: float` to Swift `Float`, and its query
serializer widens that `Float` to `Double` before printing it. Widening is exact but *unfaithful to
the literal*: `Double(Float(0.95))` is 0.949999988079071, so asking for the p95 HTTP latency sends

    GET /metrics/http-latency?quantile=0.949999988079071

Render selects a pre-computed quantile series from this value, so a request that says
0.949999988079071 is not reliably a request for p95. Removing `format: float` makes the generator
emit a `Double`, whose description round-trips the literal (`0.95` → "0.95").

Only *parameters* are touched — a response field decoded as Float loses no information on the way
in, and narrowing the app's types is not the goal. Runs after flatten-path-refs.py in
generate-api.sh; idempotent, so a fresh re-vendor keeps the fix.

As of this writing the spec has exactly one such parameter (`/metrics/http-latency`'s `quantile`).
The script walks the whole document anyway rather than hard-coding that path, because a second one
would otherwise be a silent wrong-value bug rather than a build or test failure.
"""
import json
import sys


def widen(node):
    """Strip `format: float` from every parameter schema under `node`. Returns the count."""
    changed = 0
    if isinstance(node, dict):
        for parameter in node.get("parameters", []) or []:
            schema = parameter.get("schema") if isinstance(parameter, dict) else None
            if isinstance(schema, dict) and schema.get("type") == "number" and schema.get("format") == "float":
                del schema["format"]
                changed += 1
        for value in node.values():
            changed += widen(value)
    elif isinstance(node, list):
        for value in node:
            changed += widen(value)
    return changed


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    count = widen(spec)
    print(f"  widened {count} float query parameter(s) to double", file=sys.stderr)

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
