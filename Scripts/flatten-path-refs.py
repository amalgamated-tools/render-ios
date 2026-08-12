#!/usr/bin/env python3
"""Inline deep $ref values in an OpenAPI spec so Swift code generation can resolve them.

swift-openapi-generator is built on OpenAPIKit, which only resolves references that point
into #/components/... A reference anywhere else is not resolvable at all, so generation
fails outright rather than degrading. The Render public API spec violates this in two ways:
  - #/paths/...          — intra-path parameter and schema refs (~250 of them)
  - #/components/schemas/{name}/properties/... — refs into schema sub-properties

Inlining both patterns removes the indirection without changing the effective schema.

Adapted verbatim from render-agent/scripts/flatten-path-refs.py, where the same transform
works around kin-openapi's hard reference-depth limit of 5. Only this docstring differs —
keep the two copies behaviourally identical so a future spec break is fixed once.
"""
import json
import sys
from urllib.parse import unquote


def _get(obj, pointer):
    """Resolve a JSON Pointer like #/paths/~1foo/parameters/0/schema."""
    parts = pointer[2:].split("/")  # strip leading '#/'
    parts = [unquote(p).replace("~1", "/").replace("~0", "~") for p in parts]
    for p in parts:
        obj = obj[int(p)] if isinstance(obj, list) else obj[p]
    return obj


def _should_inline(ref):
    """Return True for refs OpenAPIKit cannot resolve."""
    if ref.startswith("#/paths/"):
        return True
    # Inline any #/components/... ref that navigates into sub-properties of a
    # top-level component object (schemas, parameters, responses, etc.).
    # Top-level refs like #/components/schemas/{name} have 3 segments and are fine.
    if ref.startswith("#/components/"):
        depth = len([p for p in ref[2:].split("/") if p])
        return depth > 3
    return False


def _inline(obj, root, _seen=None):
    if _seen is None:
        _seen = set()
    if isinstance(obj, dict):
        ref = obj.get("$ref", "")
        if isinstance(ref, str) and _should_inline(ref):
            if ref in _seen:
                return obj  # circular — leave as-is
            return _inline(_get(root, ref), root, _seen | {ref})
        result = {k: _inline(v, root, _seen) for k, v in obj.items()}
        # anyOf/oneOf/allOf with a single element is equivalent to the element
        # itself. Unwrap it so the generator emits a plain type alias rather than
        # a one-case union enum.
        for kw in ("anyOf", "oneOf", "allOf"):
            if kw in result and isinstance(result[kw], list) and len(result[kw]) == 1:
                sole = result.pop(kw)
                result.update(sole[0])
                break
        return result
    if isinstance(obj, list):
        return [_inline(item, root, _seen) for item in obj]
    return obj


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)
    fixed = _inline(spec, spec)
    with open(path, "w") as f:
        json.dump(fixed, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
