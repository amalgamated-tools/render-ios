#!/usr/bin/env python3
"""Fix numeric query-parameter types whose Swift serialization Render's API rejects or misreads.

The spec types every numeric query parameter as `number`, and `swift-openapi-generator` maps that to
`Double` (or to `Float` where `format: float` is set). Both mappings serialize in ways the API does not
accept, and both failures are silent at the type level — the request compiles, sends, and comes back
wrong or 400.

Two rules, each from a confirmed live failure:

1. **`format: float` loses the literal.** The generator maps it to Swift `Float`, and its query
   serializer widens that to `Double` before printing — `Double(Float(0.95))` is 0.949999988079071.
   `/metrics/http-latency` selects a pre-computed quantile series from this value, so a request for the
   p95 said something else entirely. Dropping `format` makes the parameter a `Double`, whose
   description round-trips the literal. (Live check: Render turned out to *tolerate* the widened value
   and returned identical points for both — so this rule is correctness, not a broken feature.)

2. **Integer-parsed parameters can't be Doubles.** `resolutionSeconds` is declared `number`, so the
   generator emits `Double` and sends `resolutionSeconds=60.0` — which Render rejects outright:
   `invalid filter parameter: could not parse input 60.0 for field resolutionSeconds`. Every metrics
   chart in the app failed with a 400 until this was retyped as `integer`.

Rule 1 walks the whole document, because a second float parameter would otherwise be a silent
wrong-value bug. Rule 2 is a named list: retyping a parameter the API really does parse as a float
would break it, so each name here is one that was *observed* to reject a decimal. Add to
INTEGER_PARAMS when a new 400 like the above turns up.

Runs after flatten-path-refs.py in generate-api.sh; idempotent.
"""
import json
import sys

# Query parameters Render parses as integers, despite the spec declaring them `number`.
INTEGER_PARAMS = {"resolutionSeconds"}


def fix(node, counts):
    if isinstance(node, dict):
        for parameter in node.get("parameters", []) or []:
            if not isinstance(parameter, dict):
                continue
            schema = parameter.get("schema")
            if not isinstance(schema, dict) or schema.get("type") not in ("number", "integer"):
                continue
            if parameter.get("name") in INTEGER_PARAMS:
                if schema.get("type") != "integer":
                    schema["type"] = "integer"
                    schema.pop("format", None)
                    counts["integer"] += 1
            elif schema.get("format") == "float":
                del schema["format"]
                counts["widened"] += 1
        for value in node.values():
            fix(value, counts)
    elif isinstance(node, list):
        for value in node:
            fix(value, counts)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    counts = {"widened": 0, "integer": 0}
    fix(spec, counts)
    print(
        f"  widened {counts['widened']} float query parameter(s); "
        f"retyped {counts['integer']} as integer",
        file=sys.stderr,
    )

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
