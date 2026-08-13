#!/usr/bin/env python3
"""Add values the live API returns to enums the spec declares without them.

The generated decoder rejects an unknown enum value outright, and because the whole response is
decoded before any domain mapping happens, one legacy value fails the entire list. That is not a
theoretical risk: in the sample workspace a single Postgres on `starter_legacy` and a single one on
version `10` were enough to make the Postgres tab show "Render returned data this version of the
app doesn't understand" for all 42 databases.

Widening rather than un-enumerating on purpose: the enum is still worth having for the values that
are current, and a plain string would lose the compile-time list the display code reads. Every entry
below is a value confirmed present in a live response.

Runs after relax-nullable.py in generate-api.sh. Additive and idempotent, so a fresh re-vendor keeps
the fix and a value the upstream spec has since added isn't duplicated.
"""
import json
import sys

# (schema name, property name or None for a top-level enum schema) -> values to append
WIDENINGS = {
    # Databases created before the current plan names, still running and still billed.
    ("postgres", "plan"): ["starter_legacy"],
    ("postgresDetail", "plan"): ["starter_legacy"],
    # Postgres 10 is past end-of-life and can no longer be created, which is presumably why the
    # spec dropped it — but instances from 2018 are still there, and this app is exactly the tool
    # you'd want for looking at one.
    ("postgresVersion", None): ["10"],
}


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})

    for (name, prop), values in WIDENINGS.items():
        schema = schemas.get(name)
        if schema is None:
            print(f"  warn: schema '{name}' not found — spec may have changed", file=sys.stderr)
            continue
        if prop is not None:
            schema = schema.get("properties", {}).get(prop)
            if schema is None:
                print(f"  warn: '{name}.{prop}' not found — spec may have changed", file=sys.stderr)
                continue
        enum = schema.get("enum")
        if enum is None:
            print(f"  warn: '{name}{'.' + prop if prop else ''}' is no longer an enum", file=sys.stderr)
            continue
        for value in values:
            if value not in enum:
                enum.append(value)

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
