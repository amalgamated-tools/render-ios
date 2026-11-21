#!/usr/bin/env python3
"""Make GET /disks/{diskId}/snapshots succeed on the status Render actually sends.

The spec declares the snapshot list's success response as `201 Created`. The live API answers `200`,
as you'd expect from a GET. The generated client only decodes the statuses the spec lists, so every
successful call came back as `.undocumented(200)` and the `.created` accessor threw. The response is
renamed to `200` here, so callers use the ordinary `.ok` accessor.

Measured 2026-11 against a live workspace with 15 disks: every snapshot list returned 200.

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    try:
        responses = spec["paths"]["/disks/{diskId}/snapshots"]["get"]["responses"]
    except KeyError:
        print("  warn: GET /disks/{diskId}/snapshots not found, spec may have changed", file=sys.stderr)
        return

    if "201" in responses and "200" not in responses:
        responses["200"] = responses.pop("201")
        responses["200"]["description"] = "OK"
    elif "200" not in responses:
        print("  warn: GET /disks/{diskId}/snapshots has neither 200 nor 201, spec may have changed",
              file=sys.stderr)

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
