#!/usr/bin/env python3
"""Make one-off jobs' `status` a plain string instead of a closed enum.

The spec declares job status as `pending | running | succeeded | failed | canceled`, and the generated
decoder rejects anything else outright. Because a response is decoded whole before any mapping, one job
in a status Render adds later would fail the entire job list, and a job being polled would never be
seen to finish.

This differs from widen-enums.py, which keeps enums on purpose because display code reads their
cases. Nothing reads the generated job status cases: `JobSummary` maps the raw string to its own
`Status`, and treats a value it doesn't know as settled rather than active, so there is no list of
values to keep in sync here.

The spec inlines the job schema separately in each job operation, so this applies to all of them:
- `jobWithCursor.job.status` (GET /services/{id}/jobs)
- the inline response schemas of POST /services/{id}/jobs, GET /services/{id}/jobs/{jobId} and
  POST /services/{id}/jobs/{jobId}/cancel

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys

OPERATIONS = [
    ("/services/{serviceId}/jobs", "post", "201"),
    ("/services/{serviceId}/jobs/{jobId}", "get", "200"),
    ("/services/{serviceId}/jobs/{jobId}/cancel", "post", "200"),
]


def patch(job_schema, where):
    status = job_schema.get("properties", {}).get("status")
    if status is None:
        print(f"  warn: no `status` on {where}, spec may have changed", file=sys.stderr)
        return
    status.pop("enum", None)
    status["type"] = "string"
    status["description"] = (
        "pending, running, succeeded, failed or canceled. Free text: see Scripts/freeform-job-status.py."
    )


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    listed = spec.get("components", {}).get("schemas", {}).get("jobWithCursor", {}).get(
        "properties", {}).get("job")
    if listed is None:
        print("  warn: jobWithCursor.job not found", file=sys.stderr)
    else:
        patch(listed, "jobWithCursor.job")

    for route, method, code in OPERATIONS:
        try:
            schema = spec["paths"][route][method]["responses"][code]["content"]["application/json"][
                "schema"]
        except KeyError:
            print(f"  warn: {method.upper()} {route} {code} schema not found", file=sys.stderr)
        else:
            patch(schema, f"{method.upper()} {route}")

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
