#!/usr/bin/env python3
"""Make service events' `details` a free-form object instead of an undiscriminated `oneOf`.

The spec types `details` as a `oneOf` of ~70 shapes with no discriminator, and several members have
no required properties (`Maintenance Ended`, `Server Available`, ...). The generated decoder takes the
first member that decodes, so an empty-shaped member "matches" almost every event and the fields the
app needs — a failed deploy's exit code, an OOM kill's memory limit, an eviction's reason — are
silently dropped. That is why the timeline and the failure watcher could only ever read `type`.

As a free-form object (`type: object, additionalProperties: true`) the generator emits an
`OpenAPIObjectContainer`, which keeps every key. The app then reads the handful of fields it needs
by name, keyed on the event's `type` — which is how the API is meant to be read anyway; `type` is the
discriminator the spec forgot to declare.

Applies to both places `details` appears:
- `serviceEventWithCursor.event.details` (GET /services/{id}/events)
- the inline 200 schema of GET /events/{eventId}

Measured 2026-11 against a real workspace: `deploy_ended`, `server_failed`, `job_run_ended` and
`cron_job_run_ended` all carry `reason` objects (`nonZeroExit`, `oomKilled.memoryLimit`,
`evicted` + `evictionReason`) that the union decoder discarded.

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys

FREEFORM = {
    "type": "object",
    "additionalProperties": True,
    "description": "Type-specific details. Free-form: see Scripts/freeform-event-details.py.",
}


def patch(event_schema, where):
    props = event_schema.get("properties", {})
    if "details" not in props:
        print(f"  warn: no `details` on {where} — spec may have changed", file=sys.stderr)
        return
    props["details"] = dict(FREEFORM)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})
    listed = schemas.get("serviceEventWithCursor", {}).get("properties", {}).get("event")
    if listed is None:
        print("  warn: serviceEventWithCursor.event not found", file=sys.stderr)
    else:
        patch(listed, "serviceEventWithCursor.event")

    try:
        single = spec["paths"]["/events/{eventId}"]["get"]["responses"]["200"]["content"][
            "application/json"]["schema"]
    except KeyError:
        print("  warn: GET /events/{eventId} 200 schema not found", file=sys.stderr)
    else:
        patch(single, "GET /events/{eventId}")

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
