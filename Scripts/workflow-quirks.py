#!/usr/bin/env python3
"""Let GET /task-runs/{taskRunId} decode a run that has no results.

The spec marks `results` as a required array. The live API sends `"results": null` for any run that
didn't return a value: a failed run, a canceled one, and one still pending or running. A required
array can't decode `null`, so the generated client threw on exactly the runs most worth looking at.
Dropping `results` from `required` makes it optional, and the generated decoder reads `null` as nil.

Measured 2026-11 against a sample workflow: a failed run (4 attempts) returned `"results": null`;
a succeeded one returned `[49]`.

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    try:
        schema = spec["paths"]["/task-runs/{taskRunId}"]["get"]["responses"]["200"]["content"][
            "application/json"]["schema"]
    except KeyError:
        print("  warn: GET /task-runs/{taskRunId} not found, spec may have changed", file=sys.stderr)
        return

    required = schema.get("required", [])
    if "results" in required:
        required.remove("results")
    elif "results" not in schema.get("properties", {}):
        print("  warn: GET /task-runs/{taskRunId} has no `results`, spec may have changed", file=sys.stderr)

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
