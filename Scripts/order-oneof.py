#!/usr/bin/env python3
"""Order undiscriminated `oneOf` members so the generated first-match decoder can't misclassify.

`service.serviceDetails` is a `oneOf` with **no discriminator**, so swift-openapi-generator emits a
decoder that tries each member in declaration order and keeps the first that succeeds. That makes
the spec's ordering load-bearing: whenever one member's `required` set is a subset of another's
fields, the earlier one wins regardless of what the payload actually is.

One such pair exists:

    backgroundWorkerDetails  required: env, runtime, envSpecificDetails, plan, region,
                                       numInstances, buildPlan
    cronJobDetails           required: env, runtime, envSpecificDetails, plan, region,
                                       schedule, buildPlan

A cron job response that includes `numInstances` satisfies every `backgroundWorkerDetails`
requirement — and unknown keys like `schedule` are ignored by the generated struct — so with
`backgroundWorkerDetails` declared first, **every cron job would silently decode as a background
worker**. Swapping the two is safe in both directions: no background worker payload carries a
`schedule`, so `cronJobDetails` can never swallow one.

The other orderings are already unambiguous and are left alone:
  - `staticSiteDetails` first is fine — it requires `publishPath`, which no other member has.
  - `webServiceDetails` before `privateServiceDetails` is the correct direction: a private service's
    `required` set is a strict subset of a web service's, so putting private first would misclassify
    every web service. (The reverse risk — a private service response that carries
    `healthCheckPath` — is not expressible in the spec and has not been seen in real data.)

Runs after flatten-path-refs.py and relax-nullable.py in generate-api.sh so a fresh re-vendor keeps
the fix. Only the response schema (`service`) is reordered; `servicePOST`/`servicePATCH` are request
bodies where the app picks the case explicitly, so their order never decides anything.
"""
import json
import sys

# schema name -> (member $ref to move, member $ref to move it in front of)
REORDERINGS = {
    "service": ("#/components/schemas/cronJobDetails", "#/components/schemas/backgroundWorkerDetails"),
}


def reorder(one_of, move_ref, before_ref):
    """Move `move_ref` immediately in front of `before_ref`. Returns True when the order changed."""
    refs = [m.get("$ref") for m in one_of]
    if move_ref not in refs or before_ref not in refs:
        return None
    if refs.index(move_ref) < refs.index(before_ref):
        return False  # already ordered correctly
    member = one_of.pop(refs.index(move_ref))
    one_of.insert([m.get("$ref") for m in one_of].index(before_ref), member)
    return True


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})
    for name, (move_ref, before_ref) in REORDERINGS.items():
        one_of = schemas.get(name, {}).get("properties", {}).get("serviceDetails", {}).get("oneOf")
        if not one_of:
            print(f"  warn: {name}.serviceDetails.oneOf not found — spec may have changed", file=sys.stderr)
            continue
        result = reorder(one_of, move_ref, before_ref)
        if result is None:
            print(f"  warn: {name}.serviceDetails.oneOf is missing an expected member", file=sys.stderr)
        elif result is False:
            print(f"  {name}: already ordered")
        else:
            print(f"  {name}: moved {move_ref.rsplit('/', 1)[-1]} before {before_ref.rsplit('/', 1)[-1]}")

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
