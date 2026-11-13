#!/usr/bin/env python3
"""Make three metrics endpoints describe what Render actually accepts and returns.

Measured 2026-11 against a real workspace, read-only:

1. GET /metrics/bandwidth-sources returns the same top-level array of time series as every other
   series endpoint — labels as a `[{field, value}]` array, ISO-8601 timestamps, a `unit`. The spec
   instead describes a `{data: [...]}` envelope with a labels *object* and integer timestamps, which
   the strict generated decoder rejects on every real response. The 200 schema is replaced with a
   copy of GET /metrics/bandwidth's.

2. GET /metrics/filters/http answers `400 invalid filter parameter: resource is not a valid field`
   to the `resource` parameter the spec recommends, and works only with `service` — the one the spec
   marks deprecated. `resource` is dropped and `service` un-deprecated, so calling the endpoint the
   only way that works doesn't raise a deprecation warning.

3. GET /metrics/filters/path answers `400 invalid filter parameter: startTime is not a valid field`
   to a time range, and the same for `resolutionSeconds`. Its own description says the suggestions
   come from the most recent 5000 log lines, so there's no window to give it. All three are dropped.

Runs after flatten-path-refs.py in generate-api.sh. Shared parameters like `startTime` are still
`$ref`s to components at that point, so names are resolved through the reference. Idempotent.
"""
import copy
import json
import sys


def params(spec, path):
    item = spec["paths"][path]
    return item.setdefault("parameters", []), item["get"].setdefault("parameters", [])


def name_of(spec, param):
    """A parameter's name, following a `#/components/parameters/...` reference if it is one."""
    ref = param.get("$ref")
    if ref:
        return spec["components"]["parameters"][ref.rsplit("/", 1)[-1]].get("name")
    return param.get("name")


def drop(spec, path, names):
    for plist in params(spec, path):
        plist[:] = [p for p in plist if name_of(spec, p) not in names]


def undeprecate(spec, path, name):
    for plist in params(spec, path):
        for p in plist:
            if p.get("name") == name:
                p.pop("deprecated", None)
                p["description"] = (
                    "Service ID to query. The only resource parameter this endpoint accepts — it "
                    "rejects `resource`. See Scripts/metrics-quirks.py."
                )


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    try:
        series = spec["paths"]["/metrics/bandwidth"]["get"]["responses"]["200"]
        spec["paths"]["/metrics/bandwidth-sources"]["get"]["responses"]["200"] = copy.deepcopy(series)
    except KeyError as e:
        print(f"  warn: bandwidth-sources patch skipped, missing {e}", file=sys.stderr)

    if "/metrics/filters/http" in spec["paths"]:
        drop(spec, "/metrics/filters/http", {"resource"})
        undeprecate(spec, "/metrics/filters/http", "service")
    else:
        print("  warn: /metrics/filters/http not found", file=sys.stderr)

    if "/metrics/filters/path" in spec["paths"]:
        drop(spec, "/metrics/filters/path", {"startTime", "endTime", "resolutionSeconds"})
    else:
        print("  warn: /metrics/filters/path not found", file=sys.stderr)

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
