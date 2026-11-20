#!/usr/bin/env python3
"""Make maintenance run responses accept states the spec doesn't list yet.

A maintenance run's `state` is a closed enum in the spec (scheduled, in_progress, user_fix_required,
cancelled, succeeded, failed). The generated decoder rejects anything else, and the list is decoded
whole, so one state Render adds after this build would fail every run in the workspace. In the two
responses that carry a run it becomes a plain string, and the app maps the values it knows to its own
type, with a readable fallback for the rest.

The `state` *query* parameter on GET /maintenance keeps its enum: the app only sends states it knows.
Render answers an unknown one with 400 "invalid state ...".

Measured 2026-11 against a live workspace with no maintenance runs, so this is ahead of a failure,
not after one, for the same reason as workspace-quirks.py.

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys

NOTE = ("scheduled, in_progress, user_fix_required, cancelled, succeeded or failed. "
        "Free text: see Scripts/maintenance-quirks.py.")


def run_schema(spec, path, method, where):
    try:
        schema = spec["paths"][path][method]["responses"]["200"]["content"]["application/json"]["schema"]
    except KeyError:
        print(f"  warn: {where} 200 schema not found, spec may have changed", file=sys.stderr)
        return None
    if schema.get("type") == "array":
        schema = schema.get("items", {})
    if "$ref" in schema:
        print(f"  warn: {where} run is now a $ref, patch the shared schema instead", file=sys.stderr)
        return None
    return schema


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    for api_path, where in (("/maintenance", "GET /maintenance"),
                            ("/maintenance/{maintenanceRunID}", "GET /maintenance/{maintenanceRunID}")):
        schema = run_schema(spec, api_path, "get", where)
        if schema is None:
            continue
        state = schema.get("properties", {}).get("state")
        if state is None:
            print(f"  warn: no `state` on {where}, spec may have changed", file=sys.stderr)
            continue
        state.pop("enum", None)
        state["type"] = "string"
        state["description"] = NOTE

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
