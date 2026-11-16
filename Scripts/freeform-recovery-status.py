#!/usr/bin/env python3
"""Make Postgres point-in-time recovery's `recoveryStatus` a plain string instead of a closed enum.

The spec declares it as `AVAILABLE | BACKUP_NOT_READY | NOT_AVAILABLE`, and the generated decoder
rejects anything else outright, so a status Render adds later would fail the whole response and
the Backups screen would show an error instead of the exports it could still list.

Same reasoning as freeform-job-status.py: nothing reads the generated cases. `PostgresRecovery`
maps the raw string to its own `Status` and treats a value it doesn't know as "not available", the
safe reading, since it hides the restore button rather than offering a restore Render may refuse.

Runs after freeform-job-status.py in generate-api.sh. Idempotent.
"""
import json
import sys

ROUTE = "/postgres/{postgresId}/recovery"


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    try:
        status = spec["paths"][ROUTE]["get"]["responses"]["200"]["content"]["application/json"][
            "schema"]["properties"]["recoveryStatus"]
    except KeyError:
        print(f"  warn: GET {ROUTE} recoveryStatus not found, spec may have changed", file=sys.stderr)
    else:
        status.pop("enum", None)
        status["type"] = "string"
        status["description"] = (
            "AVAILABLE, BACKUP_NOT_READY or NOT_AVAILABLE. Free text: see "
            "Scripts/freeform-recovery-status.py."
        )

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
