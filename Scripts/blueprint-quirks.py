#!/usr/bin/env python3
"""Make blueprint statuses, sync states and resource types plain strings instead of closed enums.

The generated decoder rejects an enum value it doesn't know, and a response is decoded whole, so one
blueprint in a status Render adds later would fail the entire blueprint list, one sync in a new state
would fail the sync history, and one resource of a new type would fail the blueprint's detail. The
resource types are visibly an open set: `build_source` and `workflow` are recent additions.

As with freeform-job-status.py, nothing reads the generated cases. `Blueprint` and `BlueprintSync`
map the raw strings to their own types and show a value they don't know as Render sent it.

Covers `blueprintWithCursor.blueprint.status` (GET /blueprints), `syncWithCursor.sync.state`
(GET /blueprints/{id}/syncs), and `status` and `resources[].type` in the inline responses of
GET and PATCH /blueprints/{id}.

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys

NOTE = "Free text: see Scripts/blueprint-quirks.py."


def free_text(schema, where):
    if schema is None:
        print(f"  warn: {where} not found, spec may have changed", file=sys.stderr)
        return
    schema.pop("enum", None)
    schema["type"] = "string"
    described = schema.get("description", "")
    if NOTE not in described:
        schema["description"] = f"{described} {NOTE}".strip()


def prop(schema, *names):
    for name in names:
        if schema is None:
            return None
        schema = schema.get("properties", {}).get(name)
    return schema


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})
    free_text(prop(schemas.get("blueprintWithCursor"), "blueprint", "status"), "blueprintWithCursor.blueprint.status")
    free_text(prop(schemas.get("syncWithCursor"), "sync", "state"), "syncWithCursor.sync.state")

    for method in ("get", "patch"):
        where = f"{method.upper()} /blueprints/{{blueprintId}}"
        response = (
            spec.get("paths", {}).get("/blueprints/{blueprintId}", {}).get(method, {})
            .get("responses", {}).get("200", {}).get("content", {}).get("application/json", {}).get("schema")
        )
        free_text(prop(response, "status"), f"{where} status")
        resources = prop(response, "resources")
        if method == "get" or resources is not None:
            free_text(prop(resources.get("items") if resources else None, "type"), f"{where} resources[].type")

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
