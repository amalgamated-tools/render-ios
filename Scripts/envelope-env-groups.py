#!/usr/bin/env python3
"""Give `GET /env-groups` the cursor envelope the live API actually returns.

The spec declares the response as a bare array of `envGroupMeta`:

    [{"id": ..., "name": ..., "serviceLinks": [...]}, ...]

The live API returns the same cursor envelope every other list endpoint uses:

    [{"cursor": "1mg8...", "envGroup": {"id": ..., "name": ..., "serviceLinks": [...]}}, ...]

Measured 2026-08-12 against a real workspace with nine groups. This is not a cosmetic difference:
`envGroupMeta` marks `id`, `name`, `ownerId`, `createdAt`, `updatedAt` and `serviceLinks` required, so
the generated decoder rejects a real reply outright and the env group list fails to load at all.

The patch synthesises an `envGroupWithCursor` component matching the convention the spec already uses
for services, deploys, env vars and the rest, and points the operation's 200 at an array of it. With
that, the generated client decodes real replies and `CursorPaginator` works here like everywhere else —
which is also *simpler* than the `createdBefore` window the store needed while the response looked
cursorless.

Runs after flatten-path-refs.py in generate-api.sh. If Render ever changes the shape back, the check in
Scripts/smoke.sh flags it.
"""
import json
import sys

ENVELOPE_NAME = "envGroupWithCursor"
LIST_PATH = "/env-groups"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.setdefault("components", {}).setdefault("schemas", {})
    if "envGroupMeta" not in schemas:
        print("  warn: envGroupMeta not found — spec may have changed", file=sys.stderr)
        return

    # Same shape as the spec's own serviceWithCursor / envVarWithCursor components.
    schemas[ENVELOPE_NAME] = {
        "type": "object",
        "required": ["envGroup", "cursor"],
        "properties": {
            "envGroup": {"$ref": "#/components/schemas/envGroupMeta"},
            "cursor": {"$ref": "#/components/schemas/cursor"},
        },
    }

    operation = spec.get("paths", {}).get(LIST_PATH, {}).get("get")
    if operation is None:
        print(f"  warn: GET {LIST_PATH} not found — spec may have changed", file=sys.stderr)
        return

    content = operation.get("responses", {}).get("200", {}).get("content", {})
    schema = content.get("application/json", {}).get("schema")
    if schema is None:
        print(f"  warn: GET {LIST_PATH} 200 has no JSON schema", file=sys.stderr)
        return

    content["application/json"]["schema"] = {
        "type": "array",
        "items": {"$ref": f"#/components/schemas/{ENVELOPE_NAME}"},
    }

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
