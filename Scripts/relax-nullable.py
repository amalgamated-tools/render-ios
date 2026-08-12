#!/usr/bin/env python3
"""Relax `required` for properties Render's spec marks required but returns as `null`.

The Render spec declares some fields required and non-nullable that the live API nonetheless
sends as JSON `null`. Because the generated client decodes the *entire* response into strict
Swift types before any domain mapping happens, a single such field fails the whole decode
(e.g. the service list wouldn't load: `buildFilter.ignoredPaths` comes back null on 66 of 190
real services). Dropping the property from its schema's `required` list makes the generator emit
an optional, so the decoder's `decodeIfPresent` turns a `null` (or an absent key) into `nil`
instead of throwing.

Each entry below is a confirmed spec-vs-reality mismatch, verified against the live API. Runs
after flatten-path-refs.py in generate-api.sh, so a fresh re-vendor keeps the fix. Add a line
here when a new null-for-required field surfaces in real data.
"""
import json
import sys

# schema name -> properties to drop from that schema's `required` list
RELAXATIONS = {
    "buildFilter": ["paths", "ignoredPaths"],   # API returns ignoredPaths: null (paths too, defensively)
    "webServiceDetails": ["openPorts"],          # API returns openPorts: null
    "privateServiceDetails": ["openPorts"],
}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})
    for name, drop in RELAXATIONS.items():
        schema = schemas.get(name)
        if schema is None:
            print(f"  warn: schema '{name}' not found — spec may have changed", file=sys.stderr)
            continue
        required = schema.get("required", [])
        schema["required"] = [r for r in required if r not in drop]

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
