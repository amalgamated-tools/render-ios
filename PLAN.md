# Render for iOS — implementation plan

## Context

A native iPhone app for managing Render.com infrastructure, built greenfield.

The live spec (`https://api-docs.render.com/openapi/render-public-api-1.json`) was inspected to
confirm it can carry a real app. It can:

- **OpenAPI 3.0.2**, 130 paths / **207 operations**, every one with a unique `operationId`
  (so code generation is viable with no manual patching for name collisions).
- Global security is a single `BearerAuth` HTTP scheme — a static API key, no OAuth.
- Cursor pagination throughout (`{resource, cursor}` envelopes, `cursor`/`limit` params).
- **Real-time log streaming** over WebSocket at `GET /logs/subscribe` (HTTP 101 upgrade),
  plus historical `GET /logs`.
- Full lifecycle control: deploys, rollback, cancel, restart, suspend/resume, scale, autoscaling,
  cache purge, cron job triggers, env vars, secret files, env groups, custom domains,
  Postgres (incl. failover, recovery, credentials, top-queries), Key Value, disks, projects,
  environments, blueprints, webhooks, workflows, and ~24 metrics series.

**Intended outcome:** an "on-call peace of mind" iPhone app — fast triage of service health,
live logs, and one-tap recovery actions — built out to full dashboard parity across phases.

**Decisions already made (from your answers):**
| Decision | Choice |
|---|---|
| Networking | `swift-openapi-generator` against a **vendored, pinned** copy of the spec |
| Scope | Full parity (services, deploys, logs, metrics, env vars, secret files, Postgres, Key Value, domains, env groups) |
| Platform | iOS only, iPhone |
| Project | Hand-written `.xcodeproj` using Xcode 26 synchronized folders |

**Toolchain verified locally:** Xcode 26.6 (17F113), Swift 6.3.3, iOS 26.5 simulator runtime.
Swift 6 language mode, strict concurrency. Deployment target is **iOS 18.0**, not iOS 26 — nothing
in the app needs an iOS 26-only API, and an on-call utility is worth less if it won't install on
the phone you already have.

---

## Status

**Phase 0 is complete and verified.** See [Phase 0 outcomes](#phase-0-outcomes) for what was built,
what was measured, and where the implementation deviates from what is described below.

**Phase 1 (auth + service list) is complete**, including live smoke against a real workspace. See the
[Phase 1 milestone](#phase-1--auth--service-list-first-runnable-app--done).

**Phase 2 (service detail, deploys, actions) is complete**, including live smoke: a real deploy was
triggered from the app and watched transition to `live`. See the
[Phase 2 milestone](#phase-2--service-detail-deploys-and-the-emergency-actions--done).

**Phase 3 (logs) is complete**, including live smoke: history, the server-side filter set, and a real
WebSocket tail against a live service. See the [Phase 3 milestone](#phase-3--logs--done).

**Phase 4 (metrics) is complete**, including live smoke against a real workspace: charts against real
CPU, memory, instance, request, latency, and bandwidth series, a range change reloading at a new
resolution, and the per-service-type catalog checked on both a web service and a static site. The live
pass found **eight** defects, one of which made every chart fail. See the
[Phase 4 milestone](#phase-4--metrics--done).

**Phase 5 is split into three slices** (5a config, 5b more config, 5c datastores + org).
**5a (env vars and secret files) is complete**, including a live write round-trip — add, edit, delete
against a real service, which found three defects invisible from the read side and established that
an API config write starts no deploy. See
[Phase 5a](#phase-5a--env-vars-and-secret-files--done).

---

## Three spec gotchas that shape the design

These are concrete, verified problems — not hypotheticals — and the plan works around all three.

> **All three are now verified empirically**, not predicted. I built a scratch SwiftPM package in
> `/tmp/genprobe` and ran `swift-openapi-generator` 1.13.0 / OpenAPIKit 6.2.0 against both the raw
> and flattened spec. Results are recorded inline below.

### 1. The spec must be pre-processed before *any* generator will read it — CONFIRMED

You already hit this in `render-agent` and solved it. Reusing your solution:

- `/Users/veverkap/code/render/render-agent/scripts/generate.sh`
- `/Users/veverkap/code/render/render-agent/scripts/flatten-path-refs.py`

The spec contains **~250 `$ref`s pointing into `#/paths/...`** (e.g.
`#/paths/~1blueprints~1{blueprintId}/parameters/0/schema`) plus a handful of deep refs into
component sub-properties (`#/components/schemas/webServiceDetails/properties/disk`). I counted
these in the live spec — 34 distinct path prefixes are ref'd this way, `#/metrics/cpu` alone 60 times.

In `render-agent` the stated reason to flatten was kin-openapi's depth-5 limit. For Swift the
reason is stronger: `swift-openapi-generator` is built on **OpenAPIKit, which only resolves
references into `#/components/...`**. A `$ref` into `#/paths/...` is not resolvable at all, so
generation fails outright rather than degrading. **The flatten step is mandatory, not an
optimization.**

`flatten-path-refs.py` already handles both categories (`_should_inline` covers `#/paths/` and
`#/components/` refs deeper than 3 segments), and its single-element `oneOf`/`anyOf`/`allOf`
unwrap is a win for Swift too — it stops the generator emitting a one-case union enum where a
plain type alias is correct.

**Measured:**

| Input | Result |
|---|---|
| Raw spec | **Generation fails**: `Failed to satisfy: JSONSchema reference points to this document and can be found in components/schemas at path: .paths['/blueprints/{blueprintId}'].get.responses.200...` |
| After `flatten-path-refs.py` | **`Build complete! (42.47s)`** — 0 errors |

The script left **0** remaining `#/paths/` refs (spec grows 335 KB → 877 KB from inlining) and the
generator emitted all **207 operations**: `Client.swift` 45,794 lines + `Types.swift` 89,742 lines.
The only warnings are `'service' is deprecated`, which come from the spec's own deprecated `service`
query parameter — cosmetic, and suppressible at the call sites we wrap.

The script needed **no modifications** to work for Swift.

**Plan:** copy `flatten-path-refs.py` into `Scripts/` verbatim, updating only the docstring to cite
OpenAPIKit rather than kin-openapi. Port `generate.sh` to `Scripts/generate-api.sh` with the same
shape — download → `jq .` pretty-print → flatten → generate — swapping `go generate` for the
`swift-openapi-generator` command plugin. Keeping the two repos' pipelines identical in structure
means a future spec break is diagnosed once and fixed in both.

### 2. `service.serviceDetails` is an **undiscriminated** `oneOf` — CONFIRMED, but narrower than I first said

```
service.properties.serviceDetails:
  discriminator: null
  oneOf: [staticSiteDetails, webServiceDetails, privateServiceDetails,
          backgroundWorkerDetails, cronJobDetails]
```

The generated `Components.Schemas.service.serviceDetailsPayload` (Types.swift:5532) decodes by
**trying each case in declaration order and returning the first that succeeds** — a literal
`do { self = .staticSiteDetails(...); return } catch { errors.append(error) }` chain through all
five, then `throw DecodingError.failedToDecodeOneOfSchema`.

Whether that misclassifies depends entirely on the `required` sets, which I checked:

| Case (in try-order) | `required` |
|---|---|
| 1. `staticSiteDetails` | buildCommand, publishPath, url, buildPlan |
| 2. `webServiceDetails` | env, runtime, envSpecificDetails, plan, region, numInstances, buildPlan, **healthCheckPath**, openPorts, url |
| 3. `privateServiceDetails` | same as above **minus** healthCheckPath |
| 4. `backgroundWorkerDetails` | env, runtime, envSpecificDetails, plan, region, **numInstances**, buildPlan |
| 5. `cronJobDetails` | env, runtime, envSpecificDetails, plan, region, **schedule**, buildPlan |

So it is *mostly* safe by luck of ordering — `staticSiteDetails` will not swallow everything, since
a web service payload has no `publishPath`. **I was wrong to claim it would.** The one genuine
ambiguity is the last pair: `backgroundWorkerDetails` is tried before `cronJobDetails`, and its
required set is a strict subset of a cron job's fields *if* the API returns `numInstances` on cron
job responses. In that case **every cron job silently decodes as a background worker.**
`envSpecificDetails` is itself a nested undiscriminated `oneOf`
(`nativeEnvironmentDetails | dockerDetails`), which adds a second-order version of the same risk.

**Fix (unchanged, and cheap enough to be worth it regardless):** never consume the generated
payload enum directly. The domain layer decodes details itself, switching on the sibling
`service.type` field (`static_site | web_service | private_service | background_worker | cron_job`),
which *is* authoritative. One file, `ServiceDetails+Decode.swift`, with a fixture test per service
type — the cron-vs-worker case being the one that actually earns its keep.

The same pattern applies to `envSpecificDetails`, `servicePOST.serviceDetails`,
`servicePATCH.serviceDetails`, and `addUpdateEnvVarInput` — all undiscriminated `oneOf`s.

Note that `flatten-path-refs.py` does *not* help here — its unwrap only fires on single-element
unions, and these have 5 members. This is a genuinely separate, Swift-side fix.

### 3. The generator cannot express WebSocket or SSE

- `GET /logs/subscribe` is a `101` upgrade — hand-write it with `URLSessionWebSocketTask`.
- `GET /task-runs/events` is `text/event-stream` — hand-write or defer (Phase 5).

Everything else in the spec is `application/json` (209 sites) plus one `multipart/form-data`.

---

## Repository layout

```
RenderiOS.xcodeproj/                 hand-written pbxproj, synchronized folders
App/                                 app target sources (one synchronized root group)
  RenderApp.swift
  RootView.swift                     onboarding vs. signed-in switch
  Auth/                              token entry, Keychain, sign-out
  Workspaces/                        ScopePickerView — workspace or project scope
  Projects/                          ProjectsStore (scoping, not management)
  Services/                          list, detail, actions, events
  Deploys/                           history, detail, rollback
  Logs/                              historical + live stream UI                (Phase 3)
  Metrics/                           charts                                     (Phase 4)
  Config/                            env vars + secret files (5a); groups, domains (5b)
  Databases/                         Postgres + Key Value                       (Phase 5)
  DesignSystem/                      status colors, chips, shared views
  Assets.xcassets/                   app icon (generated by Scripts/make-app-icon.swift)
AppTests/                            target RenderiOSTests — the @Observable stores
  Support/                           shared stub-client helpers
Packages/
  RenderAPI/                         local SwiftPM package (the only dependency surface)
    Package.swift
    Package.resolved                 committed — pins the versions that produced Generated/
    openapi.json                     VENDORED + PINNED, post-flatten (877 KB)
    openapi-generator-config.yaml
    Sources/RenderAPI/
      Generated/                     committed generator output (6.4 MB, 135K lines)
      RenderClient.swift             façade: base URL, middleware stack
      RenderError.swift              one error type for the whole app
      RenderDateTranscoder.swift     ISO8601 with microseconds, as Render sends  (Phase 1)
      AuthMiddleware.swift           injects Bearer token
      StatusMappingMiddleware.swift  terminal 4xx/5xx → RenderError             (Phase 1)
      RetryMiddleware.swift          429/5xx exponential backoff + Retry-After
      Keychain.swift                 kSecClassGenericPassword wrapper           (Phase 1)
      KeychainAPIKeyProvider.swift   the token source AuthMiddleware reads      (Phase 1)
      Pagination.swift               generic cursor AsyncSequence
      LogQuery.swift                 one filter description, two transports     (Phase 3)
      LogStream.swift                URLSessionWebSocketTask log subscription   (Phase 3)
      ServiceDetails+Decode.swift    type-driven oneOf workaround               (Phase 2)
      MetricSeries.swift             one series type for 14 response types      (Phase 4)
      MetricSeries+Payloads.swift    the 42 empty conformances that collapse them (Phase 4)
      MetricsQuery.swift             one window, 14 endpoints                   (Phase 4)
    Sources/RenderAPITestSupport/    StubTransport, StubLogSocket, stub client — both suites use it
    Tests/RenderAPITests/            swift-testing; no network
Scripts/
  generate-api.sh                    download → jq → flatten → patch → generate  (port of render-agent's generate.sh)
  flatten-path-refs.py               copied from render-agent, docstring aside
  relax-nullable.py                  drops `required` for fields the API returns as null   (Phase 1)
  order-oneof.py                     orders the serviceDetails oneOf for first-match decode (Phase 2)
  number-params.py                   numeric query params Render will actually parse         (Phase 4)
  smoke.sh                           read-only live checks against a real key in .env
  run-simulator.sh                   build, install, launch
  test-destination.sh                resolves a concrete simulator for `make test-app`
  sim-input.swift                    tap/drag/type/press the booted simulator for the live pass
  make-app-icon.swift                renders the app icon asset
.github/workflows/
  ci.yml                             package tests + app build on every PR
  spec-drift.yml                     weekly re-vendor; fails when upstream moved
docs/screenshots/                    live-pass screenshots referenced from the README
Makefile                             check / build / test / run / generate / drift
```

`App/Databases/` is Phase 5c and doesn't exist yet; everything else above is on disk.

The spec and generator config sit at the **package root**, not inside `Sources/RenderAPI/`. Keeping
them out of the target's source directory means SwiftPM never sees them as unhandled resources, and
generation takes explicit paths rather than relying on magic filenames.

`Packages/RenderAPI/openapi.json` is the **post-flatten** artifact — that's what the generator and
`Package.swift` see. `generate-api.sh` writes it; it is never hand-edited.

### Why a local package, and why commit the generated code

The app target depends on **one** local package (`XCLocalSwiftPackageReference`), so the
hand-written `pbxproj` stays small and stable — all remote dependency resolution happens inside
`Packages/RenderAPI/Package.swift`, which SwiftPM owns.

Generation runs **ahead of time** by invoking the generator as a plain executable
(`swift run swift-openapi-generator generate <spec> --config <cfg> --output-directory <dir>`) with
the output **committed**, rather than using the build-tool plugin. Reasons:

1. Build-tool plugins require an interactive "Trust & Enable" prompt in Xcode and
   `-skipPackagePluginValidation` in CI — friction on every clean checkout.
2. Render explicitly warns the spec file is unversioned and structurally volatile. Committed
   output means a spec change shows up as a **reviewable diff** when you run
   `Scripts/generate-api.sh`, not as a surprise build break.
3. Incremental builds don't pay a ~40s generation cost.

The *command* plugin (`generate-code-from-openapi`) was tried first and rejected: it only discovers
`openapi.json` and `openapi-generator-config.yaml` inside the target's source directory, which
forces the spec into `Sources/` and back into SwiftPM's unhandled-resource path. The executable
takes explicit paths and has no such constraint.

`Scripts/generate-api.sh` re-downloads the spec, runs it through `flatten-path-refs.py`, writes it
to `Packages/RenderAPI/openapi.json`, regenerates, and leaves the result for `git diff` — pinning
is "the committed file", upgrading is one script run. Because the flattened spec is committed too,
an upstream change shows up as *two* reviewable diffs: the contract and the generated code.

### Dependencies

- `apple/swift-openapi-generator` (plugin, build-time only)
- `apple/swift-openapi-runtime`
- `apple/swift-openapi-urlsession`

Charts use the system `Charts` framework. No third-party UI or networking libraries.

---

## Architecture

- **SwiftUI + `@Observable`**, `NavigationStack`, Swift 6 strict concurrency.
- **Three layers:** `RenderAPI` (transport, generated types) → per-feature `@Observable` stores
  (domain models, actions, caching) → SwiftUI views. Views never touch generated types directly;
  stores map generated types into small domain structs so a spec change is absorbed in one layer.
- **Auth:** API key entered on a paste-friendly onboarding screen, validated with `GET /owners`,
  stored in Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`).
  Never in `UserDefaults`. Multi-workspace support falls out of `GET /owners` returning a list.
- **Rate limiting:** `RetryMiddleware` honors `Retry-After` on `429`, exponential backoff with
  jitter on `5xx`, capped attempts. Polling intervals back off when a view is not foregrounded.
- **Errors:** one `RenderError` enum (`unauthorized`, `rateLimited(retryAfter:)`, `notFound`,
  `server`, `transport`, `decoding`) surfaced as inline, actionable UI — not alert spam.

---

## Milestones

Each phase builds, runs, and is independently useful. Full parity is reached at Phase 5.

### Phase 0 — Foundations ✅ DONE
- Copy `flatten-path-refs.py` from `render-agent`; port `generate.sh` → `Scripts/generate-api.sh`.
- `Packages/RenderAPI` package skeleton; write `openapi-generator-config.yaml` (`types` + `client`);
  run `Scripts/generate-api.sh`; commit both the flattened `openapi.json` and the generated output.
- **First real checkpoint:** confirm the flattened spec generates clean. This is where the plan is
  most likely to need adjustment, so it happens before any UI work.
- Hand-write `RenderiOS.xcodeproj` with a `PBXFileSystemSynchronizedRootGroup` for `App/`
  and an `XCLocalSwiftPackageReference` to `Packages/RenderAPI`.
- `RenderClient`, `RenderError`, `AuthMiddleware`, `RetryMiddleware`, `Pagination`.
- **Gate:** `xcodebuild build` for the simulator succeeds; `swift test` in the package passes.

### Phase 1 — Auth + service list (first runnable app) ✅ DONE
- Onboarding / API-key entry, Keychain storage, `GET /owners` validation, workspace picker.
- `GET /services` with cursor paging, pull-to-refresh, search, filter by type.
- Status design system: label/icon/tint for the 5 service types + a suspended badge.

**Built:** `Keychain`, `KeychainAPIKeyProvider`, and `StatusMappingMiddleware` (added to `RenderAPI`);
`AuthStore`, `OnboardingView`, `ServicesStore`, `ServicesListView`, `ServiceRow`, `OwnerPickerView`,
`ServiceType+Display`, and a reworked `RootView` in the app target. `make check` green — 31 tests
in 6 suites (added `StatusMappingMiddleware` + real-stack `listOwners` pagination/401 cases),
`BUILD SUCCEEDED`, onboarding screen verified on the simulator. Live smoke (real key → list) still
needs a real API key at runtime.

**Deviations from the original outline, and why:**
1. **No per-service deploy status in the list.** The `/services` payload carries none; showing a
   live health dot would need an `N+1` deploy fetch. The list shows type + suspended only; deploy
   status lands in Phase 2 detail. (Confirmed with the user.)
2. **`ServiceDetails+Decode.swift` moved to Phase 2.** It's only needed once a screen reads
   `serviceDetails`; the list doesn't. It ships with the detail screen and its fixture tests.
3. **Status design system scoped to what the list shows** (type + suspended). The 11-value
   `deployStatus` color mapping is deferred to Phase 2, where it's first used.
4. **New `StatusMappingMiddleware`** (outermost in the stack) maps a terminal 4xx/5xx response to a
   thrown `RenderError`, so all 207 operations surface one error type without a per-operation
   `Output`-enum switch. Feature stores just `RenderError.wrapping(_:)` in their catch blocks.
5. **Filter is by type only, not status** — the list has no deploy status to filter on. Search and
   the type filter are client-side over loaded pages.
6. **Scoping grew past the workspace picker, and this write-up hadn't caught up.** What shipped is
   `ProjectsStore`, `ScopePickerView`, and `ServicesScreen` — pick a workspace *or* a project within it,
   with the project scope sent as its `environmentId`s, since services hang off environments and not off
   projects. There is no `OwnerPickerView`; it became the scope picker. Projects and environments are
   still listed under Phase 5 as "org" work, and the *management* of them is; reading them to scope the
   service list arrived early because a list of 190 services isn't usable without it.

**Live smoke turned up two spec-vs-reality mismatches** (the app's list wouldn't decode until both
were fixed — the generated client decodes the *whole* `Service` strictly before any domain mapping):
- **Microsecond timestamps.** Render sends `2026-08-11T19:59:22.275356Z` (5–6 fractional digits);
  the runtime's default ISO8601 decoder accepts at most 3. Fixed globally with
  `RenderDateTranscoder` on the client `Configuration` — affects every `Date` in the API.
- **`null` for required fields.** The spec marks `buildFilter.paths`/`ignoredPaths` and
  `serviceDetails.openPorts` required + non-nullable, but the API returns `null` (66 of 190 real
  services for `ignoredPaths`). Fixed by `Scripts/relax-nullable.py`, a spec-patch step in
  `generate-api.sh` (after flatten) that drops these from `required` so the decoder tolerates null.
  Add a line there if a new null-for-required field surfaces. Only these two exist in real data.

Both are the kind of drift PLAN.md predicted; the vendored-spec pipeline absorbed them as a
reviewable spec diff + regeneration, exactly as intended.

### Phase 2 — Service detail, deploys, and the emergency actions ✅ DONE
- Detail screen: current deploy, health, instance count, repo/branch, dashboard deep link.
- `GET /services/{id}/deploys` history and `GET .../deploys/{deployId}` detail.
- Actions with confirmation sheets: **deploy**, **rollback**, **cancel deploy**, **restart**,
  **suspend / resume**, **scale**, **purge cache**, **trigger cron run**.
- `GET /services/{id}/events` timeline.

**Built:** `ServiceDetails+Decode.swift` and `Scripts/order-oneof.py` (the `oneOf` fix, below);
`ServiceDetailStore`/`ServiceDetailView` with the actions menu and confirmation dialogs;
`ServiceAction`; `DeploySummary`, `DeploysStore`, `DeploysListView`, `DeployRow`, `DeployDetailView`;
`ServiceEventsStore`, `ServiceEventsView`; `DeployStatus+Display` (all 11 statuses, the 10 deploy
triggers, and all 42 event types); service list rows now push the detail screen instead of opening the
dashboard. `Scripts/smoke.sh` grew Phase 2 endpoint coverage plus assertions on the two spec
assumptions below. `make check` green — **43 tests in 8 suites**, `BUILD SUCCEEDED`, and the app runs
against a real workspace on the simulator.

Re-vendoring for the `oneOf` patch also picked up the first real upstream spec drift: Render added a
machine-readable `code` field to the error object and an `errorCode` enum listing its vocabulary
(currently one value, `multiple_regions`). Purely additive — nothing in the app needed changing.

**The `serviceDetails` `oneOf`, resolved — and it was worse than Phase 0 thought.** The generated
decoder tries members in *spec declaration order* and keeps the first that decodes, which makes the
spec's ordering load-bearing. `backgroundWorkerDetails` was declared before `cronJobDetails` and its
`required` set is satisfied by any cron job response that includes `numInstances` (unknown keys like
`schedule` are ignored), so **every such cron job would have decoded as a background worker**. Two-part
fix:
1. `Scripts/order-oneof.py`, a new spec-patch step in `generate-api.sh`, moves `cronJobDetails` ahead
   of `backgroundWorkerDetails`. Safe in both directions — no worker payload carries a `schedule`.
   Reordering `webServiceDetails`/`privateServiceDetails` would make things *worse* (private's required
   set is a strict subset of web's), so only the one pair moves.
2. `ServiceDetails` keys everything off the authoritative sibling `service.type` and keeps
   `decodedType` purely to detect disagreement (`matchesDeclaredType`), which the detail screen surfaces
   as "configuration may be incomplete" rather than presenting wrong fields as fact. Re-decoding the
   payload correctly is impossible after the fact: the raw JSON is gone and re-encoding a misclassified
   case has already dropped the fields that case's struct lacks — which is why the ordering patch, not
   the projection, is the real fix.

Seven fixture tests cover one case per service type plus both failure modes (the cron-job-with-
`numInstances` regression, and mismatch detection). They run through the real generated client with only
the transport stubbed, so they test the actual decoder rather than a re-implementation of it.

**Deviations from the outline above, and why:**
1. **Event rows show type + timestamp only.** `serviceEvent.details` is an undiscriminated *44*-member
   `oneOf` whose **second member has no required properties at all** — so the first-match decoder
   matches that empty member for nearly every event and calls it a success. Any field read out of it
   would be a value the decoder never looked for. (The silver lining: the union therefore cannot fail,
   so events always load.) Making details usable needs another spec patch — replace that `oneOf` with a
   free-form object so the generator emits a dictionary — which belongs with the first feature that
   needs the fields, not here.
2. **Events page by time window, not by cursor.** `serviceEventWithCursor` lists `cursor` in its
   `required` array and never defines the property, so the generator drops it and the envelope has no
   cursor at all — `CursorPaginator` is unusable. `ServiceEventsStore` instead requests each page with
   `endTime` set to the oldest event it holds, de-duplicates by ID, and stops when a page adds nothing
   new (which is also the guard against events sharing a timestamp).
3. **Rollback lives on the deploy list, not the detail screen.** The target has to be picked from
   history, and a confirmation dialog raised on a screen the user has navigated away from doesn't show.
   Same reason the scale sheet confirms in-sheet rather than handing off to the shared dialog.
4. **A failed deploy fetch doesn't blank the detail screen.** The two calls are independent, so the
   deploy leg reports its own failure ("Deploy status unavailable") — "never deployed" is a claim only a
   successful empty reply can support.
5. **Detail-screen polling only runs while a deploy is in progress**, and stops the moment it settles,
   so an idle service costs zero requests. 6s interval.
6. **No unit tests for the app-target stores** (`DeploysStore`, `ServiceEventsStore`, the action→endpoint
   mapping). The app target still has no test target — the same gap Phase 1 had. The endTime paging
   logic is the piece that most deserves one; adding an app test target to the hand-written pbxproj is a
   follow-up worth doing before Phase 3's log stream, which has real state to test.
   *(Closed: the `RenderiOSTests` target now exists — see Verification. `DeploysStore` and
   `ServiceEventsStore` still have no cases, but the harness they'd need is in place.)*

**Live smoke: done, driven from this repo.** `Scripts/sim-input.swift` (new) synthesizes taps and
drags against the booted simulator, taking coordinates straight from a `simctl` screenshot and
resolving the device-screen rect through the accessibility API at run time. That made the whole pass
scriptable — read a screenshot, tap, screenshot again. Two environment gotchas are written into its
header because both fail *silently*: the calling process needs Accessibility permission, and **the Mac
must be unlocked** (macOS drops synthesized events while the console is locked, so every tap looks
like a no-op).

Verified against a real workspace, on both an image-backed and a Git-backed service:
- Detail screen: `live` chip, plan/region/instances/runtime/repo/branch/health-check/URL all matching
  the dashboard, suspended badge with its suspender (`user`), dashboard link, "Updated 2 days ago".
- Deploy history: `live`, `deactivated`, and `build_failed` rows — all three status colors — with commit
  subject, short SHA, trigger, relative time, and duration (`1m 11s`). Deploy detail refetched cleanly.
- Events: real `deploy_started`/`deploy_ended` timeline; the `endTime` paging stopped at the end of the
  list rather than spinning.
- Actions menu gating: `resume` (not `suspend`) on a suspended service, no cron trigger on a web
  service, no cancel with nothing in flight.
- **A real deploy, end to end:** confirmation → `Deploy started.` banner → chip `Deploying` with
  "Watching for updates…" → polled to `Live` (`API · 6 seconds ago · 31s`) → polling stopped on its own.
- Backing out of a destructive action (tap outside the `restart` confirmation) does nothing at all.

**Three defects the live pass turned up, all fixed:**
1. **Wrong deploy wording for image-backed services.** The action read "Deploy Latest Commit" and the
   confirmation promised to build "the latest commit on the service's branch" for a service that has no
   branch. `ServiceAction.Source` now switches both to image wording, and "Deploy (Clear Cache)" is
   hidden for image-backed services — there's no build to cache.
2. **A long swipe could roll back with no confirmation.** `swipeActions` allows full-swipe by default,
   which *performs* the first action; on a destructive one that's a footgun. Now
   `allowsFullSwipe: false`, so the button must be revealed and tapped.
3. **Rollback was offered for the deploy already serving traffic**, which would spend a deploy to
   change nothing. It's now withheld for the newest `live` deploy — which is not always the newest
   deploy, since a failed latest attempt leaves an older one serving.

### Phase 3 — Logs ✅ DONE
- Historical `GET /logs` with the full filter set (resource, instance, level, statusCode, method,
  path, text) and direction-based paging.
- Live tail via `LogStream.swift` (`URLSessionWebSocketTask` against `/logs/subscribe`), with
  reconnect-with-backoff, pause/resume, and a bounded in-memory ring buffer.
- Monospaced log view with level coloring, search, and share/copy.

**Built:** `LogQuery` and `LogStream` (added to `RenderAPI`, plus `StubLogSocket`/
`StubLogSocketConnector` in `RenderAPITestSupport`, and a `logs` property on `RenderClient`);
`LogLine`/`LogLevel`, `LogFilter`, `LogsStore`, `LogFilterValuesStore`, `LogsView`, and
`LogFilterSheet` in the app target; a `Logs` drill-down on the service detail screen, which is why
`ownerID` now travels from the service list into the detail screen. `Scripts/smoke.sh` grew Phase 3
coverage including a real `101` handshake check. `make check` green — **52 package tests in 10 suites
and 32 app tests in 4 suites**, `BUILD SUCCEEDED`, and the whole screen driven against a real
workspace on the simulator.

**One query type, two transports.** `GET /logs` and `GET /logs/subscribe` take an identical parameter
list, but the generator emits two unrelated `Input.Query` types for them and can't express the socket
at all. `LogQuery` is the single description: `listLogsQuery(…)` projects it onto the generated
operation, `queryItems` onto the socket URL — matching the generated `style: .form, explode: true`
encoding, so `level=error&level=warning` rather than a comma join.

**`LogStream` is the only hand-written transport, and it reuses everything it can.** The frame type is
the *generated* `101` body (`LogEntryPayload`), decoded with the same `RenderDateTranscoder` leniency
the REST client needs; failures come back as `RenderError`. Three decisions worth naming:
1. **A socket that opens resets the backoff.** A tail left running all day should survive any number
   of drops, so `maxAttempts` counts *consecutive* failures. Only errors a retry could fix are
   retried — a 401 or 403 finishes the stream rather than burning six round trips to say so. A
   rejected handshake surfaces as an opaque `URLError`, so `URLSessionLogSocket` reads the status off
   `task.response` to recover the distinction.
2. **Reconnects are announced, not silent.** Render replays nothing across a gap, so
   `LogStreamEvent.connected` is re-emitted and the UI says "Reconnecting (n)…".
3. **An unrecognized frame is skipped, not fatal.** One odd frame is a bad reason to tear down a tail
   someone is watching.

**Deviations from the outline above, and why:**
1. **Paging is by the window Render returns, not by direction alone.** `/logs` is the one list endpoint
   that isn't an array of cursor envelopes: it's an object with `hasMore` + `nextStartTime` +
   `nextEndTime`. That's a *better* signal than the cursor convention — Render says when the range is
   exhausted instead of making us infer it from a short page — so `LogsStore` uses it verbatim and
   de-duplicates by ID, since the windows are inclusive at both edges.
2. **Two kinds of search, deliberately.** The filter sheet's "message contains" is server-side
   (wildcards and regex, matched by Render); the search bar filters the lines already loaded, instantly,
   and matches label values too so "the instance ID I just saw" is one paste away.
3. **The filter vocabulary is fetched, not hard-coded.** `GET /logs/values` per facet, six calls
   concurrently. Levels are per runtime — this workspace returns `alert, critical, debug, emergency,
   error, info, notice, warning` — so a hard-coded list would offer filters that match nothing. A facet
   that fails or comes back empty isn't shown; an empty picker is worse than no picker.
4. **Newest-first, not terminal order.** A phone opens at the top, and the live tail then lands above
   what you're reading instead of dragging the viewport.
5. **Pause holds lines rather than dropping them**, bounded by the same cap as the visible buffer, and
   resuming merges them in. Stopping the tail keeps whatever it already delivered.
6. **`LogLevel` is inferred, not just read.** Request logs often carry no `level`, but a 502 is an error
   whether or not anything labelled it one — so the status code fills in when the label is absent.
   Build output has neither and stays uncolored rather than being called `info`.

**Live smoke: done, driven from this repo** with `Scripts/sim-input.swift`, against a real image-backed
web service:
- History: request logs newest-first with `POST 200 /webhook` subtitles and blue severity rules.
- Filter sheet: the eight real levels above, plus `type`, `statusCode`, `method`, `instance`, `host`.
  Selecting `error` re-ran the query *and* restarted the socket on the new subscription — the list came
  back all 502/503 with red rules, and the toolbar icon filled in.
- **A real WebSocket tail:** green `Live`, the deploy's build output arriving, `Pause` → `Paused`, and
  the whole thing surviving a filter change.

**Three defects the live pass turned up, all fixed:**
1. **ANSI escape sequences rendered literally.** Build logs are colorized for a terminal and Render
   passes the escapes through, so a line read `[0;32m[1m==> [0mDetected service running on port 10000`.
   `LogLine.strippingANSI` now removes them at construction. Rendering the colors instead would mean an
   `AttributedString` per line and a palette fighting Dark Mode, for information the level rule already
   carries.
2. **`/logs/subscribe` replays recent history on connect, out of order relative to what's loaded.**
   Blind prepending put a 3:50 build line above a 3:55 one. Live lines are now inserted at their place
   in the newest-first list; the scan starts at the top, so the common case still costs one comparison.
3. **Every filter option rendered in the accent color**, reading as a row of links and leaving the
   checkmark as the only selected/unselected cue. `.buttonStyle(.plain)`.

**One thing worth knowing about the app test target:** it links `RenderAPI` twice — once as a package
framework, once statically — which the runtime warns about, and which makes `error as? RenderError`
fail across that boundary. Errors thrown by a stub *in the test target* therefore reach the store as
generic `.transport` failures. Nothing in the app is affected (it links the framework once), and the
package's own suite tests error mapping properly; app tests just shouldn't assert on a specific
`RenderError` case. Worth untangling in the pbxproj before it causes a subtler surprise.

### Phase 4 — Metrics ✅ DONE
- Swift Charts for CPU, memory, HTTP requests, HTTP latency, bandwidth, instance count,
  active connections, disk usage — each against its `-limit` / `-target` companion series where one
  exists.
- Time-range picker; batched concurrent fetches with a single spinner.

**Built:** `MetricSeries`, `MetricSeries+Payloads`, `MetricsQuery` (with `MetricKind` and
`RenderClient.metricSeries(_:_:)`), and `Scripts/number-params.py` — plus a `routed` stub in
`RenderAPITestSupport`, needed because this is the first store whose requests are concurrent;
`MetricRange`, `MetricUnit`, `MetricChartSpec`/`MetricsCatalog`, `MetricsStore`, and `MetricsView` in
the app target, reached from a `Metrics` drill-down on the service detail screen. `Scripts/smoke.sh`
grew Phase 4 coverage; `Scripts/sim-input.swift` grew `type` and `press` so the live pass could sign the
app in and drive a text field. `make check` green — **65 package tests in 11 suites and 78 app tests in
8 suites**, `BUILD SUCCEEDED`, and the whole screen driven against a real workspace on the simulator.

**Fourteen response types for one shape.** None of the `/metrics/*` schemas is a named component, so
the generator emits a separate, unrelated response type per endpoint — fourteen copies of
`{labels, values, unit}` with no common supertype, and fourteen unrelated `Input.Query` types besides.
`MetricSeries` is the one type the app sees. The collapse is a protocol whose requirements are spelled
with the *generated* property names (`labels`, `values`, `unit`), which makes all forty-two conformances
empty declarations — no mapping code to drift, and a compile error rather than a silently blank chart if
a spec change moves a field. The query side is a single `MetricsQuery` plus a fourteen-case switch,
which is where the per-endpoint asymmetry has to live: only `/metrics/cpu` accepts
`aggregationMethod`, only CPU and memory accept `instance`, and `/metrics/bandwidth` declares no
`resolutionSeconds` at all — sending one is a 400.

**PLAN.md was wrong about units, and it matters.** Phase 0 recorded that "`unit` is missing from *every*
`/metrics/*` values payload" and concluded Phase 4 "cannot read a unit off the metrics response" and
would have to hard-code one per series. Half right: the *datapoint* `unit` is indeed declared required and
never defined, so the generator drops it — but the sibling `unit` on the **series** is well-formed,
required, and present in all fourteen. So nothing hard-codes CPU as a percentage or memory as gigabytes;
`MetricUnit(apiUnit:)` maps what Render says, and its fallback case renders an unrecognized unit verbatim
rather than guessing (the failure mode being to read "MB/s" as bytes and report 4 MB/s as "4 bytes").

**One new spec patch: `Scripts/number-params.py`.** The spec types every numeric query parameter as
`number`, which the generator maps to `Double` (or `Float` under `format: float`) — and Render accepts
neither serialization. Two rules, both from confirmed failures:
1. **`resolutionSeconds` must be an integer.** As a `Double` it went out as `resolutionSeconds=60.0`, and
   Render answers `invalid filter parameter: could not parse input 60.0 for field resolutionSeconds`.
   **This 400'd every chart on the screen** — found by the live pass, not by the tests, which had pinned
   the broken value as if it were correct. Retyped as `integer` (18 sites), which makes
   `MetricsQuery.resolutionSeconds` an `Int`.
2. **`quantile` loses its literal as a `Float`.** The generator's query serializer widens Float to Double
   before printing, and `Double(Float(0.95))` is 0.949999988079071. Dropping `format: float` makes it a
   `Double` that round-trips. The live pass showed Render *tolerates* the widened value — both spellings
   returned identical points — so this rule is correctness, not a rescued feature.

Rule 1 is a named list, because retyping a genuinely fractional parameter would break it; rule 2 walks
the whole document, because a second float parameter would otherwise be a silent wrong-value bug. Tests
assert on both serializations, so a re-vendor that loses the patch fails rather than degrades. Applying
it to the vendored spec regenerated 38 lines of `Types.swift` and nothing else.

**Deviations from the outline above, and why:**
1. **No active-connections chart.** It's a datastore metric — the endpoint takes only `resource` and
   `startTime`/`endTime`, with no `service` parameter and no per-instance labels. On a service screen it
   would be a permanently empty chart. It ships in `MetricKind` and is fetchable today; the chart belongs
   with the Postgres and Key Value screens in Phase 5.
2. **Charts are chosen by service type, and the catalog is where that claim is written down.** A static
   site has no CPU (it's CDN-served, so there's no instance to measure), a worker serves no HTTP, a cron
   job's instance count would be a chart of ones and gaps. Where it's genuinely unclear whether Render
   collects a series — HTTP metrics for a private service, which serves requests but only inside the
   private network — the chart is **included**: an empty chart says "No data in this range", which is a
   mild cost, while a chart wrongly withheld hides something real and gives the user no way to find out.
   `MetricsCatalogTests` pins one case per type, so a wrong guess is one line to change.
3. **HTTP requests are grouped by status code, not totalled.** At 3am the question isn't how many
   requests there were, it's how many failed. That makes the headline a *sum* of the newest reading
   across series rather than one series' value — 10 + 6 reported as 10 would understate traffic by a
   third — which is why `MetricChartSpec.Headline` exists at all.
4. **Latency is three quantiles on one chart** (p50/p95/p99, three requests). A p50 alone hides the
   tail; a p99 alone can't say whether everything is slow or only a few things are.
5. **Reference lines never reach the headline.** A limit and a target are drawn thin and dashed and are
   excluded from the headline value: "512 MB" that turns out to be the plan's ceiling rather than the
   current reading is worse than no number.
6. **A failed series is a failed chart, not a failed screen.** Up to twelve requests means twelve chances
   to fail, and losing CPU is no reason to hide memory. The takeover error is reserved for the case where
   *nothing* arrived. `lastUpdated` is stamped only on a fully successful load, because it means "this is
   a complete picture of the window".
7. **Resolution is a property of the range, not a control.** The only reason to care is the point count,
   and that follows from the window; each of the four pairings lands between 60 and 170 points, which a
   test pins. `MetricsQuery` clamps to Render's 30-second floor on the *property*, not just the
   initializer, so a range calculation that rounds down can't earn a 400.
8. **The legend is hand-rolled and the colors are assigned explicitly**, rather than going through
   `foregroundStyle(by:)` and a Charts scale. The built-in legend can't show that a reference line is
   dashed, and a hand-rolled one whose swatch colors drift from the plot is worse than none — so one
   function colors both.
9. **No polling.** Pull-to-refresh only. A metrics screen left open is not a deploy in flight, and the
   Phase 2 precedent is that polling has to earn itself.

**Live smoke: done, driven from this repo** with `Scripts/sim-input.swift`, against a real workspace —
a Go web service with traffic and a static site. Verified: CPU and memory against their plan limits,
instance count, request count, p50/p95/p99 latency, and bandwidth; the range picker reloading 1H → 24H
at the coarser resolution and redrawing the axis in 6-hour steps; the catalog's per-type claims (the
static site offers bandwidth *only*, and it has real data — so that guess was right).

**Eight defects the live pass turned up, all fixed.** The first two are the reason this phase wasn't
called done without it:

1. **Every chart failed with a 400.** `resolutionSeconds` is declared `number`, so the generated
   parameter was a `Double` and the request said `resolutionSeconds=60.0` — which Render rejects:
   `could not parse input 60.0 for field resolutionSeconds`. The screen showed eight cards all reading
   "Couldn't load this metric". Worth dwelling on: a unit test *asserted* `resolutionSeconds=60.0`,
   because a test can only pin what its author already believes. Fixed by retyping the parameter as
   `integer` in `Scripts/number-params.py`.
2. **`unitless` rendered as a suffix.** Render sends it for request and instance counts, and the
   fallback case turned a one-instance service into "1.00 unitless". Now a plain count.
3. **A distant limit flattened the reading.** An idle service uses 0.0001 of its 0.5-core limit, and
   plotting both put the usage line indistinguishable from the axis — on CPU *and* memory, the two
   charts most likely to be looked at first. A reference line now only joins the y-scale when it's
   within 2.5× of the readings; past that it becomes a caption ("Limit 0.5 cores"), which loses only
   the false precision of a line nobody can read against.
4. **CPU axis labels all read "0".** Cores were abbreviated to three decimals to keep labels short,
   which erased an entire axis living below 0.001. They now keep four.
5. **The latency headline disagreed with its own chart** — "1 ms" above a plot topping out at 4 ms,
   because "newest timestamp" let the p50 win a race against the p99. The headline is now the highest
   current reading across the measurement lines, which is also the number worth knowing at 3am.
6. **`ByteCountFormatter` renders zero as "Zero KB"**, so a quiet memory chart's baseline gridline was
   a small puzzle. Now "0".
7. **Bandwidth drew three gridlines all labelled "0 MB".** Its readings were non-zero but negligible,
   giving a domain too small for any tick to differ. Each unit now declares an axis floor.
8. **Bandwidth drew no line at all** — a 3.39 MB headline above an empty plot. Render buckets bandwidth
   itself, and a one-hour window came back as a *single point*; a line through one point renders
   nothing. A one-point series is now drawn as a mark.

**Two findings outside Phase 4, both recorded rather than acted on:**
- **`GET /services/{id}/events` now returns a cursor.** `Scripts/smoke.sh` flagged it: the envelope that
  declared a `cursor` it never defined now has one. `ServiceEventsStore`'s `endTime` paging (Phase 2,
  deviation 2) can be replaced with `CursorPaginator` on a re-vendor. Nothing is broken today.
- **The smoke script's WebSocket check was wrong, not the API.** It reported `HTTP/2 426` because curl
  negotiated HTTP/2, and a WebSocket upgrade is an HTTP/1.1 mechanism. With `--http1.1` it's `101` as
  before. `URLSessionWebSocketTask` speaks 1.1 for the handshake, so the app was never affected — but a
  check that cries wolf is worse than no check.

**`Scripts/sim-input.swift` grew `type` and `press`**, since driving this phase meant signing the app in
rather than tapping through a screen it was already on. Both had to be gotten wrong first, and both
failure modes were silent: keyboard events built with a `nil` event source drop the shift modifier
entirely (so "_" arrives as "-" and every capital arrives lowercased), and `keyboardSetUnicodeString` is
ignored altogether — the Simulator honors the key *code*, so every character posted with `virtualKey: 0`
arrives as "a". A 32-character API key became 32 a's and the app reported, accurately, that the key was
rejected. `type` reads from stdin so a key stays out of argv and the shell history.

**`make run` was launching onto the wrong simulator.** Since CI got its own device, the device lookup's
substring match picked "CI iPhone 17 Pro" when asked for "iPhone 17 Pro" — which looks exactly like the
app failing to launch on the simulator you're watching. Now anchored to the start of the name.

### Phase 5 — Full parity

Split into three shippable slices, because "full parity" is four screens' worth of work per bullet
and each of the three is independently useful on its own:

- **5a — Service config:** env vars, secret files. *(Done, live-verified both ways — see below.)*
- **5b — More config:** env groups and their links, custom domains (add, verify, delete), headers,
  routes.
- **5c — Datastores + org:** Postgres (list, detail, connection info, suspend/resume/restart,
  failover, recovery, credentials, top-queries / sizes / processes / table-scans), Key Value
  (list, detail, connection info, suspend/resume); projects, environments, blueprints + syncs,
  disks + snapshots, webhooks, maintenance, notification settings, audit logs.

Secret values are revealed behind an explicit tap and never logged.

#### Phase 5a — Env vars and secret files ✅ DONE

**Built:** `ConfigActionResult`, `SecretValueView`, `EnvVarsStore`/`EnvVarsView`/`EnvVarEditor`, and
`SecretFilesStore`/`SecretFilesView`/`SecretFileEditor` in a new `App/Config/`, reached from two new
drill-downs on the service detail screen. `Scripts/smoke.sh` grew read-only Phase 5 coverage.
`make check` green — **65 package tests in 11 suites and 100 app tests in 10 suites**,
`BUILD SUCCEEDED`, both screens driven against a real workspace on the simulator.

Nothing new was needed in `RenderAPI`: both resources are ordinary cursor collections and ordinary
JSON writes, so the stores call the generated client directly. The first phase since Phase 0 that
added no transport-layer workaround.

**Decisions worth naming:**
1. **Writes address one key at a time, never the whole-list PUT.** The API offers both
   (`PUT /services/{id}/env-vars` replaces the entire set); the whole-list form would silently
   delete anything added from the dashboard, or by a teammate, since the screen last loaded. Editing
   `LOG_LEVEL` from a phone must not be able to take a colleague's new variable down with it.
2. **Every write is announced as a redeploy**, in the editor footer and again in the result banner,
   because that's what Render does with a config change and it isn't obvious from "Save".
3. **Values are masked per row and revealed one at a time**, resetting on every navigation. The
   reveal is the real protection; `privacySensitive()` is applied too, but it only covers Lock
   Screen and Always-On rendering — iOS has no API to exclude a view from a screenshot, so PLAN's
   original "excluded from screenshots via a redaction modifier" was a promise the platform can't
   keep. Said plainly rather than implied. The *editors* don't mask at all (defects 4 and 5 below):
   a masked field you can only replace, that also offers itself to the keychain, is worse than an
   honest one — and reaching an editor takes a deliberate tap on a row that is masked.
4. **Search matches keys only.** Matching values would tell the user which variable holds the string
   they typed, which is precisely what the mask exists to prevent.
5. **The whole collection is drained rather than paged on scroll.** A config screen showing *some*
   of the configuration is a trap, and a service has tens of variables, not hundreds.
6. **Neither editor renames.** Render addresses both resources by name, so a rename is a delete plus
   a create — two calls whose failure between them leaves a half-applied config. Deleting and adding
   is the same work, done where the user can see it.
7. **Secret file contents come from the list.** `GET /secret-files` returns `content` for every file
   (verified live), so opening the editor costs no second request. `smoke.sh` watches that, since the
   spec marks `content` required — if Render ever stops sending it the whole list stops decoding.
8. **A failed refresh keeps what's on screen.** On a config screen the difference between "no
   variables" and "we couldn't ask" is the difference between a shrug and a page.

**The most important thing this phase learned: an API config write does not deploy.** Render applies
`PUT /services/{id}/env-vars/{key}` to the service's configuration immediately, but — unlike the same
edit made in the dashboard — it starts no deploy. Measured, not assumed: an add, an update, and a
delete against a live service produced **no new deploy row and no deploy event**, before and after.
So the running instances keep the old value until something else deploys them, and every message in
these screens says when the change actually takes effect rather than claiming a redeploy. A
"saved" that silently means "not live yet" is exactly the misunderstanding that costs an hour at 3am.
*(Follow-up worth doing: offer **Deploy** straight from the success banner, since "I changed a
variable" is almost always followed by "…and now I need it live".)*

**Live pass: done, both sides.** Read side against `render-oidc-discovery-dev` in Render-Prod — env
vars loaded masked and alphabetized, per-row reveal showed one value and left the others masked, and
the secret file screen listed `jwks.pem` as "4 lines · 177 bytes" with its contents behind a Reveal.
Write side against `bifrost:latest` in Patrick's Workspace, a full round-trip driven from the app and
checked against the API after every step: **add** (`IOS_SMOKE=phase5a`) → **edit** → **delete**, then
a second pass to confirm the fixes. The service was left exactly as found: no env vars, no new
deploys.

**Five defects the live pass turned up, all fixed.** The last three came from the write side and none
of them were visible without it:
1. **A locked key looked like an empty field.** Both editors rendered the non-editable identifier as
   a disabled `TextField` in secondary colour — visually identical to placeholder text, so an editor
   opened on `RENDER_ENV` read as though it had lost the key it was editing. Now plain text with a
   footer that says renaming isn't possible.
2. **Save was enabled before anything changed**, so a curious tap on an env var could write back the
   value already there. It's now disabled until the value differs — which the secret file editor
   already did, and the env var editor didn't.
3. **Every success message promised a redeploy that never happened** — see above. Two tests now pin
   the wording, because this is a claim about Render's behaviour and a future edit could quietly
   re-introduce the optimistic version.
4. **Editing a value silently discarded it.** A `SecureField` prefilled with existing text clears
   itself on the first keystroke, so appending "-2" to "phase5a" saved a value of exactly `-2` — data
   loss with a success banner over it. The value field is now a plain `TextEditor`.
5. **iOS offered to save the value to the user's password manager.** Any `SecureField` trips
   AutoFill's save-credential heuristic, so dismissing the sheet raised "Save Password?" over a
   Render env var. `.textContentType(.oneTimeCode)` did *not* suppress it (tried, and re-tested
   live); dropping `SecureField` did — which is the same fix as defect 4. The masking that matters
   happens in the list, where a value sits on screen without anyone having asked for it.

### Phase 6 — Polish
- Widgets / Live Activity for an in-flight deploy.
- Background refresh + local notifications on deploy failure (note: true push requires a server
  to receive Render webhooks — out of scope here; call it out as a follow-up).
- Accessibility pass, Dynamic Type, VoiceOver labels on status chips.

---

## Critical files

| File | Role |
|---|---|
| `Scripts/flatten-path-refs.py` | Makes the spec readable by OpenAPIKit at all; from `render-agent` |
| `Scripts/order-oneof.py` | Orders the `serviceDetails` `oneOf` so the first-match decoder can't misclassify a cron job |
| `Scripts/number-params.py` | Makes numeric query parameters serialize the way Render parses them — `resolutionSeconds=60`, not `60.0` |
| `Packages/RenderAPI/openapi.json` | The pinned, flattened contract; the single point of upstream drift |
| `Packages/RenderAPI/Sources/RenderAPI/ServiceDetails+Decode.swift` | Works around the undiscriminated `oneOf` — the highest-risk code in the app |
| `Packages/RenderAPI/Sources/RenderAPI/RetryMiddleware.swift` | 429 handling; the app polls, so this is load-bearing |
| `Packages/RenderAPI/Sources/RenderAPI/LogStream.swift` | The only hand-written transport |
| `RenderiOS.xcodeproj/project.pbxproj` | Hand-written; synchronized folders keep it churn-free |
| `Scripts/generate-api.sh` | Makes spec upgrades a reviewable diff |

---

## Verification

**Unit (no network), every phase:**
```
make test          # both suites
make test-package  # RenderAPI only — fast, no simulator
make test-app      # app target only — needs a simulator
```

*Package* (`Packages/RenderAPI/Tests`), fixture-driven `swift-testing` cases: `ServiceDetails`
decoding for all 5 service types, cursor pagination termination, `RetryMiddleware` backoff on a
stubbed 429 with `Retry-After`, `RenderError` mapping for 401/403/404/429/5xx.

*App* (`AppTests/`, target `RenderiOSTests`): the `@Observable` stores, driven through the real
generated client with only the transport stubbed — so a test covers the query a store actually
builds, not a re-implementation of it.

Transport is stubbed via `RenderAPITestSupport`, a product of the RenderAPI package rather than a
file in one test target, because both suites need it and a test target's sources aren't visible
outside it. No live calls in tests: an API key is a user secret and CI runs offline.

Running the app tests needs a *concrete* simulator (`generic/platform=iOS Simulator` builds but
can't run), so `Scripts/test-destination.sh` resolves one at run time instead of pinning a device
that a CI image may stop shipping.

**Build + simulator, every phase:**
```
xcodebuild -project RenderiOS.xcodeproj -scheme RenderiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```
then `make run` and drive the app to confirm the phase's screens work. Driving is scriptable:

```
swift Scripts/sim-input.swift tap 600 1349          # coords read off a simctl screenshot
swift Scripts/sim-input.swift drag 600 2200 600 1200
xcrun simctl io booted screenshot /tmp/step.png
```

Needs Accessibility permission **and an unlocked Mac** — see the script's header; both failure modes
are silent no-ops.

**Live smoke test:** needs a real Render API key, entered in the app's onboarding screen at
runtime. Nothing in the repo, tests, or CI ever holds a key. Per phase, confirm against a real
workspace: Phase 1 — services list matches the dashboard; Phase 2 — a triggered deploy appears and
transitions status; Phase 3 — live tail emits lines within seconds of a request; Phase 4 — charts
match dashboard metrics; Phase 5 — an env var round-trips.

Driving the app now includes signing it in, since the Keychain starts empty on a fresh simulator:

```sh
swift Scripts/sim-input.swift tap 600 1035              # the API key field
printf '%s' "$RENDER_API_KEY" | swift Scripts/sim-input.swift type   # stdin, so it stays out of argv
swift Scripts/sim-input.swift press return
```

**Spec drift check:** `Scripts/generate-api.sh` then `git diff --stat Packages/RenderAPI` —
an empty diff means upstream is unchanged.

---

## Phase 0 outcomes

Everything in Phase 0 is built and verified. `make check` is green.

**Measured:**

| Gate | Result |
|---|---|
| `swift test` (Packages/RenderAPI) | **25 tests, 4 suites, all passing** in 0.005s — no network |
| `xcodebuild … -destination 'iPhone 17 Pro'` | **BUILD SUCCEEDED** |
| App launches on simulator | Yes — `RootView` renders, `RenderAPI` links |
| Generation | 207 operations, `Client.swift` 45,794 lines + `Types.swift` 89,742 lines, ~42s |

**Deviations from the plan above, and why:**

1. **Deployment target is iOS 18.0, not iOS 26.** No iOS 26-only API is needed, and restricting an
   on-call tool to the newest OS costs real device coverage for nothing.
2. **Generation uses the executable, not the command plugin** — see
   [Why a local package](#why-a-local-package-and-why-commit-the-generated-code).
3. **`namingStrategy: idiomatic`** is set, so generated names read like Swift
   (`Components.Schemas.Service`, `client.listServices(_:)`) rather than mirroring the spec's
   lowercase style. Worth locking in now: switching it later is a 135K-line diff.
4. **`RenderClient` exposes the generated `Client` as `api`** rather than re-declaring methods.
   Hand-wrapping 207 operations would be duplication with no abstraction gain; the layer that
   actually earns its keep is the per-feature store that maps generated types to domain types.

**Two things Phase 0 turned up that affect later phases:**

- **The spec has typos that silently drop fields.** The generator warned on ~15 sites where a
  property appears in a `required` list but not in `properties`, so it is skipped entirely. These
  cluster in the metrics endpoints (`unit` is missing from every `/metrics/*` **datapoint**) and
  in `GET /workflowversions/{id}` (`image`, `updatedAt`).
  ~~**Phase 4 cannot read a unit off the metrics response** and will have to hard-code units per
  series.~~ **Corrected in Phase 4:** the dropped `unit` is the one on each *datapoint*; the
  series-level `unit` beside it is well-formed and present on all fourteen endpoints, so units are
  read from the response after all. See the [Phase 4 milestone](#phase-4--metrics--done).
- **`RetryMiddleware` gates 5xx retries on HTTP method.** A 429 means the request was rejected
  unprocessed, so it is replayed for any method; a 5xx may mean the request *was* processed, so it
  is only replayed for GET/HEAD/PUT/DELETE/OPTIONS. Without that gate, a 500 on
  `POST /services/{id}/deploys` could trigger a second deploy. There is a test named for exactly
  this (`a 500 is NOT retried for POST`) — don't relax it.

---

## Open items

1. ~~Generation smoke test.~~ **Retired in Phase 0.** Flattened spec generates all 207 operations
   and compiles clean. The `multipart/form-data` operation and all 13 `oneOf` sites were handled
   without needing a `filter:`.
2. **App name / bundle identifier.** Currently `RenderiOS` / `com.veverkap.RenderiOS`.
   "Render" is a third-party trademark; fine for personal use, worth a rename before any App Store
   submission. Changing it now is cheap — two `PRODUCT_BUNDLE_IDENTIFIER` lines in the pbxproj.
3. **Generated-code size.** 6.4 MB / 135K lines committed, ~30s to compile clean. Acceptable, but
   if incremental build times bite, `filter:` in `openapi-generator-config.yaml` can trim
   generation to the tags the app actually uses. Not doing this up front — full parity is the goal.
4. ~~**No CI yet.**~~ **Done.** `.github/workflows/ci.yml` runs the package tests and an app build
   on every PR and every push to `main`, using the same `make` targets as local development.
   `.github/workflows/spec-drift.yml` re-runs `make generate` weekly and fails when Render has
   changed the spec out from under the vendored copy.
5. ~~**PR-preview services dominate the list.**~~ **Done.** `ServicesStore.makePaginator` now sends
   `includePreviews: false` so the list shows real services only. A toggle to show previews is a
   later refinement.
6. **`GET /services/{id}/events` now returns a cursor.** Found by `Scripts/smoke.sh` during the Phase 4
   live pass: the envelope that declared a `cursor` it never defined now carries one, so
   `ServiceEventsStore`'s `endTime` paging (Phase 2, deviation 2) can become an ordinary
   `CursorPaginator` after the next re-vendor. Nothing is broken today — the current paging still
   works — so this is a simplification, not a fix.
7. **The app test target links `RenderAPI` twice.** Noted in Phase 3 and still true: `error as?
   RenderError` fails across that boundary, so app tests assert on error *presence* rather than case.
   Worth untangling in the pbxproj before it causes a subtler surprise.
