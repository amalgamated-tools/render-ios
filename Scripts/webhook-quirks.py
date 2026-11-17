#!/usr/bin/env python3
"""Make webhook responses decode what Render actually sends.

Two mismatches, both measured against the live API (2026-11):

1. `eventFilter` is declared a required array, but a webhook with no filter, meaning one that gets
   every event, comes back as `"eventFilter": null`. Left required, that fails the whole webhook
   list, so it is made optional in every webhook response.
2. Event types are a closed enum of ~70 values, and Render adds new ones over time. A delivery for a
   type this build doesn't know would fail the whole delivery history, and a filter holding one
   would fail the webhook. Render also stores any string in a filter without checking it. So in
   responses, `eventFilter` items and a delivery's `eventType` are made plain strings.

Requests keep the enum. The app only sends event types it knows, and the generated request type
gives it that list.

Covers `webhookWithCursor.webhook` (GET /webhooks), the inline responses of POST /webhooks,
GET /webhooks/{id} and PATCH /webhooks/{id}, and `webhookEventWithCursor.webhookEvent`
(GET /webhooks/{id}/events).

Runs after flatten-path-refs.py in generate-api.sh. Idempotent.
"""
import json
import sys

RESPONSES = [
    ("/webhooks", "post", "201"),
    ("/webhooks/{webhookId}", "get", "200"),
    ("/webhooks/{webhookId}", "patch", "200"),
]


def free_text(schema, note):
    schema.pop("enum", None)
    schema["type"] = "string"
    schema["description"] = f"{note} Free text: see Scripts/webhook-quirks.py."


def patch_webhook(schema, where):
    props = schema.get("properties", {})
    if "eventFilter" not in props:
        print(f"  warn: no `eventFilter` on {where}, spec may have changed", file=sys.stderr)
        return
    schema["required"] = [name for name in schema.get("required", []) if name != "eventFilter"]
    items = props["eventFilter"].get("items")
    if items is not None:
        free_text(items, "An event type.")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "openapi/render.json"
    with open(path) as f:
        spec = json.load(f)

    schemas = spec.get("components", {}).get("schemas", {})

    listed = schemas.get("webhookWithCursor", {}).get("properties", {}).get("webhook")
    if listed is None:
        print("  warn: webhookWithCursor.webhook not found", file=sys.stderr)
    else:
        patch_webhook(listed, "webhookWithCursor.webhook")

    for route, method, code in RESPONSES:
        try:
            schema = spec["paths"][route][method]["responses"][code]["content"]["application/json"][
                "schema"]
        except KeyError:
            print(f"  warn: {method.upper()} {route} {code} schema not found", file=sys.stderr)
        else:
            patch_webhook(schema, f"{method.upper()} {route}")

    delivery = schemas.get("webhookEventWithCursor", {}).get("properties", {}).get("webhookEvent")
    event_type = (delivery or {}).get("properties", {}).get("eventType")
    if event_type is None:
        print("  warn: webhookEventWithCursor.webhookEvent.eventType not found", file=sys.stderr)
    else:
        free_text(event_type, "The type of the event delivered.")

    with open(path, "w") as f:
        json.dump(spec, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
