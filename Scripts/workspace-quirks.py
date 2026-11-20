#!/usr/bin/env python3
"""Make workspace member and audit log responses accept values the spec doesn't list yet.

The spec declares closed enums for an audit log entry's `event` (87 values), `status` and actor
`type`, and for a member's `role` and `status`. The generated decoder rejects anything else, and a
response is decoded whole, so one audit event or role added by Render after this build would fail
the entire audit log or member list. These are lists Render grows: the audit events alone name
most of the product.

So in responses they become plain strings, and the app maps the values it knows to its own types,
with a readable fallback for the rest. The member role in the PATCH *request* keeps its enum: the
app only sends roles it knows, and the generated type gives it that list.

`teamMember.role` and the PATCH response's `role` are `$ref`s to `teamMemberRole`, which the request
shares, so they are replaced by inline strings rather than editing the shared schema.

Measured 2026-11 against a live workspace: every value seen was still in the spec. This is ahead
of a failure, not after one, for the same reason as webhook-quirks.py.

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys

ROLE_NOTE = "ADMIN, DEVELOPER, WORKSPACE_CONTRIBUTOR, WORKSPACE_BILLING or WORKSPACE_VIEWER."


def free_text(schema, note):
    schema.pop("enum", None)
    schema.pop("$ref", None)
    schema["type"] = "string"
    schema["description"] = f"{note} Free text: see Scripts/workspace-quirks.py."


def prop(schema, name, where):
    found = schema.get("properties", {}).get(name)
    if found is None:
        print(f"  warn: no `{name}` on {where}, spec may have changed", file=sys.stderr)
    return found


def patch_member(schema, where):
    for name, note in (("role", ROLE_NOTE), ("status", "active or inactive.")):
        found = prop(schema, name, where)
        if found is not None:
            free_text(found, note)


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})

    audit = schemas.get("auditLog")
    if audit is None:
        print("  warn: auditLog not found", file=sys.stderr)
    else:
        for name, note in (("event", "The type of event, such as CreateServerEvent."),
                           ("status", "success or error.")):
            found = prop(audit, name, "auditLog")
            if found is not None:
                free_text(found, note)

    actor = schemas.get("auditLogActor")
    actor_type = prop(actor, "type", "auditLogActor") if actor is not None else None
    if actor_type is not None:
        free_text(actor_type, "user, rest_api or system.")

    member = schemas.get("teamMember")
    if member is None:
        print("  warn: teamMember not found", file=sys.stderr)
    else:
        patch_member(member, "teamMember")

    try:
        updated = spec["paths"]["/owners/{ownerId}/members/{userId}"]["patch"]["responses"]["200"][
            "content"]["application/json"]["schema"]
    except KeyError:
        print("  warn: PATCH /owners/{ownerId}/members/{userId} 200 schema not found", file=sys.stderr)
    else:
        # Currently a $ref to teamMember, already patched above; only an inline copy needs it.
        if "$ref" not in updated:
            patch_member(updated, "PATCH /owners/{ownerId}/members/{userId}")

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
