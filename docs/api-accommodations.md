# Where the Render API isn't what the spec says

Every item here is a **confirmed** mismatch between Render's published OpenAPI spec (or its documented
behaviour) and what the live API actually does, together with the accommodation the app makes for it.
Nothing on this list is hypothetical — each was found either by generation failing, by a decode
failing against real data, or by a live pass driving the app against a real workspace.

The reason so many of these are load-bearing: **the generated client decodes the entire response into
strict Swift types before any domain mapping happens**, so one `null` in one field of one record fails
the whole request. There is no partial decode and no "ignore the field I don't need".

Read this before adding a screen, and add to it when a new mismatch surfaces. `README.md`'s
[Working with the spec](../README.md#working-with-the-spec) is the short version; `PLAN.md` has the
per-phase narrative.

---

## A. Fields marked `required` that come back `null`

Patched by `Scripts/relax-nullable.py`, which drops the property from its schema's `required` list so
the generator emits an optional and `decodeIfPresent` turns `null` into `nil`.

| Field | What Render sends | Impact before the fix |
|---|---|---|
| `buildFilter.ignoredPaths` (and `paths`, defensively) | `null` on **66 of 190** real services | The service list — the app's first screen — didn't load at all |
| `webServiceDetails.openPorts`, `privateServiceDetails.openPorts` | `null` | Same: any service with a null port list failed |
| `Logs200Response.logs` | `null`, not `[]`, for a window with no lines — **7 of 20** services at the default range | "Couldn't load logs" on a service whose only problem was being quiet; the "Nothing was logged in this time range" empty state was unreachable |
| `ipAllowList` on `postgres`, `postgresDetail`, `keyValue`, `keyValueDetail` | `null` for a datastore with no rules — every Key Value instance in the sample workspace, and a fresh free-tier Postgres the moment it's created | Both datastore tabs showed "Render returned data this version of the app doesn't understand" in place of the whole list |
| `postgresDetail.project` | absent entirely on a database that isn't in a project | Same — the Postgres detail screen couldn't load |

The logs entry needed the script extended to reach response bodies inline under
`components/responses`, since that schema isn't a named component. The two `ipAllowList.count` call
sites unwrap the optional.

## B. Structural problems that break or corrupt code generation

| # | Problem | Accommodation |
|---|---|---|
| 1 | ~250 `$ref`s point into `#/paths/…`; OpenAPIKit only resolves into `#/components/…` | `Scripts/flatten-path-refs.py` inlines them. **Generation fails outright** without it — mandatory, not an optimization |
| 2 | `service.serviceDetails` is an undiscriminated `oneOf`, so the generated decoder keeps the first member that decodes — making spec declaration order load-bearing. `cronJobDetails`' required set is satisfied by any cron job carrying `numInstances` (unknown keys like `schedule` are ignored), so **every cron job silently decoded as a background worker** | `Scripts/order-oneof.py` moves `cronJobDetails` ahead of `backgroundWorkerDetails`. On the Swift side `ServiceDetails+Decode.swift` keys every field off the authoritative sibling `service.type` and keeps `decodedType` only to *detect* disagreement, which the detail screen surfaces as a warning |
| 3 | `GET /env-groups` is documented as a bare array of `envGroupMeta`; it returns the `{envGroup, cursor}` envelope every other list uses. With six required fields on `envGroupMeta`, the decoder **rejected every real reply** | `Scripts/envelope-env-groups.py` synthesises `envGroupWithCursor` and points the operation at it. `EnvGroupsStore` then became an ordinary `CursorPaginator` — simpler than the `createdBefore` window it needed while the response looked cursorless |
| 4 | `resolutionSeconds` is typed `number` → Swift `Double` → `resolutionSeconds=60.0`, which Render rejects: `invalid filter parameter: could not parse input 60.0`. **This 400'd every metrics chart on the screen** | `Scripts/number-params.py` retypes it as `integer` (18 sites). Found by the live pass, not the tests — a unit test had pinned `60.0` as if it were correct |
| 5 | **Enums the live API overruns.** `postgres.plan` has no `starter_legacy` and `postgresVersion` has no `10` — values Render no longer lets you create and still runs. An unlisted value fails the whole response, so **one 2018 database emptied a list of 42** | `Scripts/widen-enums.py` adds the missing values, additively and idempotently, so a re-vendor keeps the fix and an upstream addition isn't duplicated. Widened rather than dropped: the documented values are still worth having as a compile-time list, which the display code reads |
| 6 | `/metrics/http-latency`'s `quantile` carries `format: float`; the generator's query serializer widens `Float` to `Double` before printing, so a p95 request goes out as `0.949999988079071` | Same script drops `format`. Render turned out to *tolerate* the widened value, so this is correctness, not a rescued feature |

Pipeline order (`Scripts/generate-api.sh`):

```
download → jq pretty-print → flatten-path-refs.py → relax-nullable.py → widen-enums.py
         → order-oneof.py → envelope-env-groups.py → number-params.py → generate
```

## C. Timestamps

**Render returns microsecond precision** (`2026-08-11T19:59:22.275356Z`, 5–6 fractional digits); the
runtime's default ISO8601 decoder accepts at most 3. This is not one field — it's every `createdAt` /
`updatedAt` in the API, so it failed the service list outright.

`RenderDateTranscoder` is installed on the client `Configuration` and reused by `LogStream` for
WebSocket frames, so REST and socket decode dates identically.

## D. Success statuses the spec gets wrong

The generated `.noContent` / `.created` accessors throw on anything undocumented, so each of these
turned a *successful* write into an error banner over a change Render had already made.

1. **`PUT /services/{id}/secret-files/{name}` answers `200`, not the documented `201`** — and the body
   it returns describes an *env var* (`{"key","value"}`), not a secret file. Every real create threw:
   the file was written and the app said "Couldn't reach Render". `SecretFileBackend` now accepts any
   2xx and builds the row from what was *sent* — the one write in the app where Render isn't the
   authority on what it stored, because it doesn't say.
2. **`DELETE /env-groups/{id}/services/{id}` answers `200`, not `204`.** An unlink Render had already
   performed was reported as a failure, with the stale row left on screen claiming a link that no
   longer existed.
3. Because that was the **third** instance, the rule was centralized: `NoContentWrite` in `RenderAPI`
   treats **any 2xx** as success for the nine no-body writes the app makes, with tests pinning that a
   real failure is still a failure.
4. **`GET /services/{id}/routes` on a non-static-site answers `400`** (`invalid service type. Only
   static sites have routes`), not the `406` the spec advertises — and headers/routes turned out to be
   static-site-only, which narrowed `ServiceConfigCatalog`'s applicability gate.

## E. Response shapes the stores handle defensively

- **The `{"headers": …}` wrapper is fiction on both edge-rule writes.** `POST .../headers` returns a
  **bare header** and `PATCH .../routes/{id}` a **bare route** — and on routes the spec's key is
  `headers`, a copy-paste slip. Both fields are optional, so the *fallback* path (re-read the list, or
  record what was asked for) is what runs every time; the documented path is dead code until Render
  ships the shape it advertises.
- **`deployWithCursor` marks both members optional** though the API always sends both.
  `DeploysStore.Envelope` resolves the optionality and drops a malformed envelope, which at worst ends
  paging a page early.
- **`GET /logs` is not the cursor convention.** It returns `{hasMore, nextStartTime, nextEndTime}` with
  windows inclusive at both edges — a *better* signal than a cursor, so `LogsStore` uses it verbatim and
  de-duplicates by ID.
- **`/logs/subscribe` replays recent history on connect**, out of order relative to what's loaded, so
  live lines are inserted at their place in the newest-first list rather than prepended.
- **Build logs carry ANSI escape sequences** passed straight through; `LogLine.strippingANSI` removes
  them at construction.
- **Log filter vocabularies are per-runtime.** `GET /logs/values` returns eight levels in this
  workspace, so a hard-coded list would offer filters that match nothing.

## F. Fields the spec declares that the generator has to drop

- **`serviceEventWithCursor.cursor`** is listed in `required` and never defined, so the generator drops
  it and the envelope has no cursor at all — `CursorPaginator` is unusable. `ServiceEventsStore` pages
  by `endTime` window, de-duplicating by ID. *(Render has since started returning a cursor; this can
  become an ordinary paginator on a re-vendor — open item 6 in `PLAN.md`.)*
- **The metrics *datapoint* `unit`** appears in `required` but not in `properties`, so it's dropped. The
  series-level `unit` beside it is well-formed and present in all fourteen endpoints, which is why
  nothing hard-codes a unit per chart.
- **`serviceEvent.details` is a 44-member undiscriminated `oneOf` whose second member has no required
  properties at all**, so first-match decoding matches that empty member for nearly every event and
  calls it a success. Any field read out of it would be a value the decoder never looked for — event
  rows therefore show type and timestamp only. (Upside: the union can't fail, so events always load.)
- **No `/metrics/*` schema is a named component**, so the generator emits fourteen unrelated copies of
  `{labels, values, unit}` plus fourteen unrelated query types. `MetricSeries` collapses them behind a
  protocol spelled with the generated property names, so all forty-two conformances are empty
  declarations — a compile error rather than a blank chart if a spec change moves a field.

## G. Behaviour that differs from the docs or the dashboard

1. **An API config write does not deploy.** Render applies `PUT /services/{id}/env-vars/{key}`
   immediately but — unlike the same edit made in the dashboard — starts **no deploy**. Measured, not
   assumed: an add, an update, and a delete against a live service produced no deploy row and no deploy
   event. Every message in the config screens says when the change actually takes effect, and the
   success banner offers a **Deploy** button precisely because of this.
2. **`POST /deploys` has two success codes** — `201` created, and `202` accepted when there's nothing to
   build. One implementation, in `DeploysStore`.
3. **Render validates none of the edge rules and renumbers priorities itself.** Duplicate route
   sources, duplicate header name+path, and `priority: 0` are all accepted with `201`; deleting one rule
   shifted the survivors (1, 2, 9 → 2, 3, 10) with relative order intact. The app's "append at max + 1"
   reads a possibly-stale max, and `sorted(by: <)` is unspecified on a tie — open item 13.
4. **`DELETE` on an unknown route or header ID answers `204`** (idempotent — the report of success is
   true), while **`PATCH` on a missing route answers `404`** with the bare message "Not found."
5. **`/metrics/bandwidth` declares no `resolutionSeconds`** — sending one is a `400` — and Render buckets
   it itself, so a one-hour window can come back as a *single point* (which is why a one-point series is
   drawn as a mark, not a line).
6. **`/metrics/active-connections` takes no `service` parameter.** It's a datastore metric, fetchable
   today but permanently empty on a service screen.
7. **`unitless` is a real unit string** Render sends for request and instance counts; rendered as a
   suffix it turned a one-instance service into "1.00 unitless".
8. **The OAuth device-flow endpoints aren't in the spec at all**, and the token endpoint wants a **JSON
   body with an `application/x-www-form-urlencoded` Content-Type**. Mirrored from Render's open-source
   CLI and preserved rather than "fixed" — see `OAuth/RenderOAuthClient.swift`.
9. **The task-run metrics need a parameter the spec doesn't declare, and count per workflow.**
   `/metrics/task-runs-queued` and `/metrics/task-runs-completed` answer every request with `400 ...
   does not support aggregation method NONE` until it carries `aggregationMethod=SUM`, which
   `Scripts/metrics-quirks.py` adds as a required parameter. Their `resource` is documented as a task
   ID, but a task ID returns zeros; a workflow ID returns counts, and those include the workflow's flow
   runs. Completed counts come in UTC-day buckets that count in full even when the window starts
   mid-day, and hourly buckets over a week answer `500`. The queued series came back unlabelled, with a
   value that matched no queued runs, so the app doesn't show it. Measured 2026-11-22, read-only.
10. **`GET /task-runs/events` sends the whole run, not the spec's event shape, and only terminal
    states.** Each `task.completed` frame carries the full run, the same shape as `GET /task-runs/{id}`,
    where the spec's example shows a smaller object. `TaskRunEventStream` decodes only `id` and `status`
    so either shape works, and the run screen reloads the run for the rest. A run that already finished
    gets its event as soon as the stream opens, and the stream closes itself once every requested run
    has finished. Nothing reports Pending → Running, so the run screen still polls, more slowly while
    the stream is connected. The generator can only deliver the body once the response ends, so the
    transport is hand-written, like `LogStream`. Checked 2026-11-22 with runs in the write-test
    workspace.

---

## Upstream drift seen so far (no action needed)

- A machine-readable `code` field on the error object plus an `errorCode` enum (`multiple_regions`,
  later `duplicate_saved_search_name`) — purely additive.
- The `429` response now documents `Retry-After` and the `RateLimit-*` headers. `RetryMiddleware`
  already read `Retry-After`.
- `GET /services/{id}/events` now returns the `cursor` it used to declare and omit (see F).

`.github/workflows/spec-drift.yml` re-runs `make generate` weekly and fails when Render has changed the
spec out from under the vendored copy. `Scripts/smoke.sh` asserts the live shape of the patched
endpoints, so if Render ever ships the *documented* behaviour, the corresponding patch can be removed
rather than silently doing the wrong thing.
