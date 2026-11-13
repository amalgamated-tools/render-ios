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

**5b (env groups, custom domains, headers, routes) is complete**, including live write round-trips for
env groups and custom domains. The live pass corrected two things nothing else could have: `GET
/env-groups` returns a cursor envelope the spec doesn't describe, which meant the env group list
**couldn't decode a single real reply**; and headers/routes are static-site-only, which the app had
guessed wrong. It also caught a third instance of Render answering with an undocumented status — an
unlink that succeeded and was reported as a failure. See [Phase 5b](#phase-5b--env-groups-custom-domains-headers-routes--done).

**5c's core is complete** — the Postgres and Key Value tabs: list, detail, connection info, and
lifecycle actions, reusing the Logs and Metrics screens. Its live pass found the app unusable against
a real workspace for a reason no test could have: three spec-vs-reality mismatches, each of which
lost an entire list. The rest of 5c (projects, environments, blueprints, disks, webhooks, audit logs,
and Postgres' recovery/credentials/top-queries) is not built. See
[Phase 5c](#phase-5c--postgres-and-key-value--core-done).

**Three things landed alongside the phases, outside their numbering:**

- **OAuth device-authorization sign-in**, ported from Render's open-source CLI and now the default
  way in, with a pasted API key kept as the fallback. See
  [OAuth sign-in](#oauth-sign-in--done).
- **A UI pass** that took the app from wireframe to product: the brand palette wired as the global
  accent, a launch screen carried into the first frame, a hero onboarding screen, skeleton loading,
  one shared error state, motion and haptics on caused state. See [Phase 6](#phase-6--polish).
- **TestFlight preparation** — privacy manifest, encryption declaration, version 1.0, and
  `make archive` / `make ipa`. See [distribution](#distribution).

**Phase 6's failure notifications are complete on the device-local side**: a watchlist, a background
refresh, and a local notification that deep-links to the service that broke, plus a screen that also
surfaces Render's own email/Slack settings. True push is *not* built and needs a server — see
[Phase 6 — Failure notifications](#phase-6--failure-notifications--done-device-local-half).

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

*(A third hand-written transport arrived later for a different reason: Render's OAuth endpoints
aren't in the spec at all. See [OAuth sign-in](#oauth-sign-in--done).)*

**Three gotchas were what the design had to be shaped around; they were not the last of them.** The
pre-processing pipeline has grown from one script to six, every addition forced by a live response
the generated decoder rejected. The running inventory — every relaxed field, widened enum, wrong
success status, undocumented response shape, and behavioural surprise, with what each one broke — is
in [`docs/api-accommodations.md`](docs/api-accommodations.md).

---

## Repository layout

```
RenderiOS.xcodeproj/                 hand-written pbxproj, synchronized folders
App/                                 app target sources (one synchronized root group)
  RenderApp.swift
  RootView.swift                     splash, then onboarding vs. signed-in switch
  PrivacyInfo.xcprivacy              required-reason API declaration (UserDefaults)  (TestFlight)
  Auth/                              device flow + key entry, Keychain, sign-out
  Workspaces/                        WorkspaceScreen (4 tabs) + ScopePickerView             (5b)
  Projects/                          ProjectsStore (scoping, not management)
  Services/                          list, detail, actions, events
  Deploys/                           history, detail, rollback
  Logs/                              historical + live stream UI                (Phase 3)
  Metrics/                           charts                                     (Phase 4)
  Config/                            env vars + secret files (5a); env groups, domains,
                                     headers, routes (5b)
  Databases/                         Postgres + Key Value                            (5c)
  DesignSystem/                      StatusChip, GlyphTile, SkeletonList, ErrorStateView,
                                     SplashView, Theme
  Assets.xcassets/                   brand colours + marks (Scripts/make-brand-assets.swift)
Resources/Info.plist                 UILaunchScreen only; merged into the generated plist
AppTests/                            target RenderiOSTests — the @Observable stores
  Support/                           shared stub-client helpers
Packages/
  RenderAPI/                         local SwiftPM package (the only dependency surface)
    Package.swift
    Package.resolved                 committed — pins the versions that produced Generated/
    openapi.json                     VENDORED + PINNED, post-flatten + patched (860 KB)
    openapi-generator-config.yaml
    Sources/RenderAPI/
      Generated/                     committed generator output (6.6 MB, 141K lines)
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
      NoContentWrite.swift           any 2xx is a success for a no-body write   (Phase 5b)
      OAuth/                         device flow, token storage, refreshing provider  (OAuth)
    Sources/RenderAPITestSupport/    StubTransport, StubLogSocket, StubOAuthTransport, stub client
    Tests/RenderAPITests/            swift-testing; no network
Scripts/
  generate-api.sh                    download → jq → flatten → patch → generate  (port of render-agent's generate.sh)
  flatten-path-refs.py               copied from render-agent, docstring aside
  relax-nullable.py                  drops `required` for fields the API returns as null   (Phase 1)
  order-oneof.py                     orders the serviceDetails oneOf for first-match decode (Phase 2)
  number-params.py                   numeric query params Render will actually parse         (Phase 4)
  envelope-env-groups.py             the cursor envelope GET /env-groups really returns      (Phase 5b)
  widen-enums.py                     plans and versions Render still runs but no longer lists (5c)
  smoke.sh                           read-only live checks against a real key in .env
  run-simulator.sh                   build, install, launch
  test-destination.sh                resolves a concrete simulator for `make test-app`
  sim-input.swift                    tap/drag/type/press the booted simulator for the live pass
  make-brand-assets.swift            renders the app icon and the in-app marks
  capture-screenshots.sh             re-shoots docs/screenshots from the walkthrough's coordinates
  walkthrough-lib.sh                 the tour: beats, coordinates, and the driver both recorders share
  record-walkthrough.sh              records docs/walkthrough.mov + its beats file
  record-walkthrough-oauth.sh        the same tour, signing in through the device flow
  verify-walkthrough.sh              one frame per beat, tiled — did the tour visit what it narrates
  beats-to-srt.py / burn-captions.sh beats → SRT → hard-subbed mp4
  ExportOptions.plist                account-agnostic export config for `make ipa`
.github/workflows/
  ci.yml                             package tests + app build on every PR
  spec-drift.yml                     weekly re-vendor; fails when upstream moved
docs/screenshots/                    the README's screenshot set (Scripts/capture-screenshots.sh)
docs/api-accommodations.md           every spec-vs-reality mismatch found so far
Makefile                             check / build / test / run / generate / drift /
                                     walkthrough* / archive / ipa
```

Everything above is on disk.

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
- **Auth:** two ways in, one credential at a time — the OAuth device flow (default) or an API key
  pasted on the fallback — both validated with `GET /owners` and stored in Keychain
  (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`). Never in `UserDefaults`.
  Multi-workspace support falls out of `GET /owners` returning a list.
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
  routes. *(Done, live-verified — see below.)*
- **5c — Datastores + org:** Postgres (list, detail, connection info, suspend/resume/restart,
  failover, recovery, credentials, top-queries / sizes / processes / table-scans), Key Value
  (list, detail, connection info, suspend/resume); projects, environments, blueprints + syncs,
  disks + snapshots, webhooks, maintenance, notification settings, audit logs.
  *(Core done — both datastore tabs, live-verified. The org half is not built; see below.)*

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
*(Follow-up: offer **Deploy** straight from the success banner, since "I changed a variable" is
almost always followed by "…and now I need it live". Done — see
[the follow-up below](#phase-5a-follow-up--deploy-from-the-config-banner--done).)*

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

#### Phase 5a follow-up — Deploy from the config banner ✅ DONE

The other half of 5a's central finding. The banner already said a saved change waits for the next
deploy; now it can *be* that deploy. A successful write — save or delete, env var or secret file —
offers **Deploy Latest Commit** (or **Latest Image**) right there, behind the same confirmation the
detail screen's action menu uses. The alternative was backing out of two screens to find the menu,
which is exactly the friction that leaves a variable saved and not running.

**Built:** `ConfigDeployer` and a shared `ConfigResultBanner` in `App/Config/`;
`ConfigActionResult` gained `offersDeploy`; both stores gained a `deployer` and `deployNow()`;
`DeploysStore.createDeploy` now owns the create-deploy call that `ServiceDetailStore` used to hold
privately. `make check` green — **65 package tests in 11 suites and 115 app tests in 11 suites**,
`BUILD SUCCEEDED`, both screens driven against a real image-backed service.

**Decisions worth naming:**
1. **The deploy call moved to `DeploysStore`, not copied.** Two screens now start deploys, and
   `POST /deploys` is the one operation with two documented success codes (201 created, 202 accepted
   with nothing to build). That nuance is worth exactly one implementation.
2. **No cache-clearing variant in the banner.** A clean build is a debugging tool, not what someone
   wants after editing a variable, and two buttons would turn the quick path into a decision.
3. **Confirmed, like every other action that touches a live service.** This one is a single tap from
   a banner, which is the reason it isn't a single tap from a build. The dialog names the service,
   since the banner doesn't. Copy comes from the existing `ServiceAction.deploy` case, so the two
   confirmations can't drift — including the image-vs-commit wording that Phase 2's live pass had to
   fix once already.
4. **Cron jobs get no button.** A cron job runs, it doesn't deploy, so `ConfigDeployer.make` returns
   `nil` and the banner stays a report.
5. **"Deploy started", not "deployed".** The endpoint is asynchronous and a build takes minutes.
   Claiming the change is live the moment the request returns would repeat, one step later, the exact
   misunderstanding this affordance exists to correct. The result of a deploy also stops offering a
   deploy, so the banner can't invite a second build of the same commit.
6. **The banner became one shared view.** Both config screens reported identically already; the
   deploy path — confirmation copy, in-flight spinner, per-service wording — is more than either
   screen should be carrying its own copy of.

**Live pass: done, and it closed the loop 5a left open.** Against `bifrost:latest`
(`srv-d9kgm85g1s2s739e6ft0`, image-backed) in Patrick's Workspace, checked against the API at every
step. Add `IOS_SMOKE_DEPLOY=banner` → the banner read "saved. It takes effect on the next deploy."
with **Deploy Latest Image** — the image wording, taken from the service, not assumed. The API
confirmed the variable was written and, once again, that **no deploy had been created**. Tapping
Deploy → "Deploy bifrost:latest? Pulls and deploys the latest image from the service's registry." →
`dep-d9ui1uu417fc7388t1j0`, `deploy_started`, and the banner became "Deploy started. The change is
live when it finishes." It reached `live` four minutes later — the first time in this app that a
config change has actually become the running configuration. Both the save and the delete path offer
it, on both screens. The service was left as found: no env vars, no secret files, and a second
deploy from the delete banner to put the running instances back where they started.

**Two defects, both found only because the live pass went through the write path:**
1. **Creating a secret file reported a failure Render hadn't had.** `PUT /secret-files/{name}`
   answers **200**, not the 201 its own spec documents — and the body it sends back describes an
   *env var* (`{"key","value"}`), not a secret file. The store read `.created`, so every real create
   threw: the file was written, and the app said "Couldn't reach Render". 5a's unit test had pinned
   the spec's version of events rather than Render's, which is exactly the kind of claim only a live
   pass can settle. Now any 2xx is accepted and the row is built from what was *sent* — the one write
   in the app where Render isn't the authority on what it stored, because it doesn't say.
2. **An error banner rendered the entire HTTP response.** The failure above surfaced as twenty lines
   of red — every header, the rate-limit counters, Cloudflare's ray ID — over the list. `RenderError`
   now clamps a wrapped description to 180 characters. These messages are read by someone deciding
   what to do next, not pasted into a bug report.

#### Phase 5b — Env groups, custom domains, headers, routes ✅ DONE

**Built:** `ConfigScope`, `EnvVarBackend`, `SecretFileBackend`, `EnvGroupSummary`, `EnvGroupsStore`/
`EnvGroupsListView`, `EnvGroupDetailStore`/`EnvGroupDetailView` (rename, link picker),
`ServiceEnvGroupsStore`/`ServiceEnvGroupsView`, `CustomDomainsStore`/`CustomDomainsView`,
`HeaderRulesStore`/`HeaderRulesView`, `RouteRulesStore`/`RouteRulesView`, and `ServiceConfigCatalog` in
`App/Config/`; `WorkspaceScreen` in `App/Workspaces/`; `NoContentWrite` in `RenderAPI`;
`Scripts/envelope-env-groups.py`. Four new drill-downs on the service detail screen and a second tab at
the root. `make check` green — **65 package tests in 11 suites and 161 app tests in 19 suites**,
`BUILD SUCCEEDED`, and every screen driven against real workspaces on the simulator.

**5a's screens were reused rather than copied, which is most of why this slice was affordable.** Env
vars and secret files exist twice in the API — on a service and on an env group — and the two differ in
only three ways, all forced by the API: a service's are a paginated collection while a group's arrive
*inline with the group* (`GET /env-groups/{id}` carries them; there is no per-group list endpoint); a
service write answers with the one variable while a group write answers with the **whole group**; and a
service's change waits on one deploy while a group's waits on every linked service's. So
`EnvVarsStore`/`SecretFilesStore` took a backend instead of a service ID, `ConfigScope` owns the two
sentences that differ, and the views, editors, masking, and every 5a decision carried over untouched.
All 115 of 5a's app tests passed against the refactor without modification, which is the evidence that
the reuse didn't quietly change service-scoped behaviour.

**Decisions worth naming:**
1. **Env groups are a tab, not a drill-down**, because there is no `GET /services/{id}/env-groups` —
   the link is recorded only in each group's `serviceLinks`. `WorkspaceScreen` now owns the scope
   picker, the account menu, and `ProjectsStore`, so both tabs agree about the active workspace; 5c's
   datastores land in the same tab bar.
2. **The group list ignores the project scope**, unlike the service list beside it. A group can be
   owned by the workspace and linked to services across projects, so an `environmentId` filter would
   *hide* a group the current project is using — and `environmentId` on a create is a single ID where a
   project scope resolves to several, so creating one would mean guessing. Groups are created
   workspace-wide, and the list says so in its footer rather than leaving the missing filter to be
   noticed.
3. **A group write gets no Deploy button.** 5a's banner can offer a deploy because one service's change
   is one build away from live. A group feeds *N* services, so the honest thing is to say which ones are
   waiting — "It takes effect on the next deploy of the 3 linked services" — rather than fan out N
   deploys from one tap. Linking or unlinking *does* offer it: that changes exactly one service.
4. **A group rename is a real rename.** Render addresses groups by ID, so unlike an env var key or a
   secret file name (5a, deviation 6) this is a `PATCH` rather than a delete-plus-create — and the sheet
   says it needs no deploy, because every other rename in this app is impossible.
5. **Header and route rules can be added and deleted, but not edited.** The only per-rule writes are
   `DELETE` and (for routes) a `PATCH` that carries `priority` alone. Editing would mean either the
   whole-list `PUT` that 5a ruled out as a lost-update hazard, or a delete-plus-add whose failure in
   between leaves a service with a rule missing. The screens say so in a footer instead of hiding it.
6. **Route order is the screen.** Rules are evaluated in priority order and the first match wins, so the
   list is numbered and reordering is a swipe away — it's the main reason to reopen the screen. A move
   is two `PATCH`es, because setting one priority alone would leave two rules claiming the same one; if
   the second fails, the list reloads rather than showing a half-applied order.
7. **A new route goes last.** A rule inserted at the front could shadow every existing one, and the
   newest rule is the one you're least sure about.
8. **Deleting a custom domain is announced as immediate.** Every other config change in these screens
   waits for a deploy; this one takes a hostname off the internet the moment it returns.
9. **Verification is reported as "checking", never as verified.** `POST .../verify` answers `202` with
   no body — it has queued a DNS check, not passed one — so the store re-reads the list and reports what
   the status actually is. Claiming a verification the API never confirmed is the same class of lie 5a
   found in "Render is redeploying the service".
10. **402 and 409 get their own sentences.** A payment-required or already-claimed domain isn't a retry
    or a bug; it's a fact to act on elsewhere, and "Request failed (402)" tells the reader nothing.

**Deviations from the outline above, and why:**
1. **`ServiceConfigCatalog` withholds where Phase 4's catalog would include.** An unavailable metrics
   chart says "No data in this range"; an unavailable config endpoint *fails*. So the applicability rules
   are conservative, with one pinning test per service type — the opposite default to Phase 4, on
   purpose.
2. **The group list is drained, not paged on scroll** — same reasoning as 5a's config screens: a partial
   list of shared configuration invites someone to create a second group that already exists.
3. **No secret-file or env-var *reveal* changes.** The masking, per-row reveal, and key-only search are
   5a's, unchanged, and now cover groups for free.

**Two spec-vs-reality findings, the first of which made the feature not work at all:**
1. **`GET /env-groups` returns a cursor envelope the spec doesn't describe.** The spec declares a bare
   array of `envGroupMeta`; the live API sends `{envGroup, cursor}` like every other list endpoint. Since
   `envGroupMeta` marks six fields required, the generated decoder **rejected every real reply** — the
   env group list could not load at all. Fixed by `Scripts/envelope-env-groups.py`, a new spec patch
   that synthesises `envGroupWithCursor` and points the operation at it; `EnvGroupsStore` then became an
   ordinary `CursorPaginator`, which is *simpler* than the `createdBefore` window it needed while the
   response looked cursorless. `Scripts/smoke.sh` now fails loudly if the envelope ever disappears.
2. **Headers and routes are static-site-only, and Render says so with `400`, not the `406` the spec
   advertises.** `GET /services/{id}/routes` on a real web service answers
   `invalid service type. Only static sites have routes`. The catalog's first guess — static sites *and*
   web services, which read like the safe one — was wrong, and it's now static sites only, with Render's
   own message passed through untouched because it names the problem better than anything the app could
   invent. Confirmed from both sides live: a web service offers Env Groups and Custom Domains only; a
   static site offers all four.

Re-vendoring for the envelope patch also picked up additive upstream drift: a new `errorCode`
(`duplicate_saved_search_name`) and the `429` response now documenting `Retry-After` and the
`RateLimit-*` headers. Nothing in the app needed changing — `RetryMiddleware` already reads
`Retry-After` off the response.

**Live pass: done, driven from this repo** with `Scripts/sim-input.swift`, checked against the API after
every write.

*Env groups, write side*, in Patrick's Workspace: created a scratch group (`is-5b-smoke`) → added
`IOS_5B_SMOKE=phase5b` → linked `bifrost:latest` → unlinked it from the **service** side → re-linked →
unlinked from the **group** side → deleted the group. The workspace was left exactly as found: only the
two pre-existing production groups, no env vars or domains on `bifrost:latest`, and — measured before and
after — **no new deploys**, which extends 5a's central finding to linking and unlinking. Production
groups were only ever read.

*Custom domains, write side*, on the same service: `ios-5b.example.com` added (Unverified chip, "Point a
CNAME record…", `Check DNS Now`) → verify returned "Checking … It stays unverified until the DNS record
resolves." → removed, with the confirmation stating that traffic stops immediately. Pasting
`https://…/x` into the field was rejected before it could be sent.

*Headers and routes, read side*, against real static sites in Render-Prod-Internal: `policy-css`'s two
real CORS rules rendered grouped by path (`Access-Control-Allow-Methods: GET, OPTIONS` on
`/custom.css`), and the routes screen loaded `200` — which is what proves the catalog gate is right,
since the same call 400s on a web service. The write side had to wait for a scratch site; see the
[edge-rule write pass](#edge-rule-write-pass--done) below.

**Three defects the live pass turned up, all fixed. The first is the one that mattered:**
1. **An unlink that succeeded was reported as a failure.**
   `DELETE /env-groups/{id}/services/{id}` answers **200**, not the documented `204`, and the generated
   `.noContent` accessor throws on anything undocumented — so the app said "Couldn't reach Render:
   Unexpected response…" over a link that Render had already removed, and left the stale row on screen
   claiming a link that no longer existed. This is the **third** time this spec has lied about a success
   status (5a: secret file `PUT` answers 200, not 201; and its group twin), so the rule now lives in one
   place: `NoContentWrite` in `RenderAPI` treats **any 2xx** as success for the nine no-body writes the
   app makes, and three tests pin it — including that a real failure is still a failure.
2. **A footer read "Shared by every linked service. no linked services."** Lower-casing the link summary
   and appending it produced a sentence that repeated itself and, at zero, contradicted itself. It's now
   one sentence chosen by count, including a "reaches no services" case that says the thing worth
   knowing.
3. **The navigation title was squeezed to "Servic…" on one tab and dropped entirely on the other.** The
   scope picker and an inline title can't share the bar. The picker now takes the *title* slot, which is
   also the more useful thing to read there — the tab bar already names both screens.

#### Edge-rule write pass ✅ DONE

Run against `nextjs-static` (`srv-d9ujumajobas73b0k1i0`) in Patrick's Workspace — a scratch static site
created for exactly this, which is what open item 8 was waiting for. Every screen state was driven from
the simulator and every write checked against `GET` afterwards.

*Routes:* a populated list rendered in evaluation order for the first time on a device (rewrite `/api/*`
before redirect `/old`) → added `/docs → https://render.com/docs` from the app, which appended at
priority 3 → swiped **Up**, which swapped it with `/old` (two `PATCH`es; screen and API agreed on
2/3 afterwards) → swipe-deleted `/old`. *Headers:* the list loaded, `X-App-Live: bangui` on `/*` was
added from the app and sorted **above** the pre-existing `X-Smoke-One` as the by-path-then-name order
promises, then `X-Smoke-One` was removed. Every banner offered Deploy and named the rule it had changed.

**No defects in the app. Four things about the API worth writing down:**
1. **The spec's `{"headers": …}` wrapper is fiction on both writes.** `POST .../headers` returns a **bare
   header** and `PATCH .../routes/{id}` a **bare route**, not the object-under-a-plural-key the spec
   declares. Both stores already treat that field as optional — the header add falls back to re-reading
   the list, the reorder to recording what it asked for — so the *fallback* is the path that runs every
   time, and the live pass is what proves it. The primary path is dead code until Render ships the
   documented shape.
2. **`DELETE` on a route or header is idempotent: an unknown ID answers `204`.** Deleting a rule that had
   already been deleted out from under the screen reported success, and that report is *true* — the rule
   is gone. This is the one write in the app that can't produce the "lied about a write" failure the
   Phase 5b unlink did.
3. **`PATCH` on a missing route answers `404`, and the reorder failure branch handles it correctly.**
   Deleting a rule behind the app's back and then swiping **Up** on it produced a red banner and a list
   reloaded to the server's true state, exactly as designed for a half-applied swap. The banner reads
   "Not found." — Render's own message, honest but terse; see open item 10.
4. **Render validates none of this and renumbers priorities on its own.** Duplicate route sources,
   duplicate header name+path, and `priority: 0` are all accepted with `201`; deleting one rule shifted
   the surviving rules' priorities (1, 2, 9 → 2, 3, 10) without changing their relative order. The screen
   shows order, not numbers, so nothing was visibly wrong — but the app's "append at max+1" reads a
   possibly-stale max, and `sorted(by: <)` on a tie is unspecified. See open item 13.

**The pass also found a hazard in the tooling, not the app.** Two Conductor workspaces both built and
launched `com.veverkap.RenderiOS` onto the shared `iPhone 17 Pro` simulator, so a sibling agent's install
replaced the bundle and terminated the app mid-pass — and for several screenshots the app under test was
*another branch's build*, which read exactly like four missing drill-down rows. `Scripts/sim-input.swift`
now takes `SIM_DEVICE` (a device name, matched against the Simulator's window title) so a workspace can
drive its own device: `Scripts/run-simulator.sh "bangui iPhone 17 Pro"` then
`SIM_DEVICE="bangui iPhone 17 Pro" swift Scripts/sim-input.swift tap …`. Unset behaves as before. **A live
pass on the shared device while another workspace is building is not trustworthy** — the first symptom is
an app that dies on a tap and a UI missing things the source clearly has.

**One of Phase 3's open items closed itself in the process.** The app test target linked `RenderAPI`
twice, which made `error as? RenderError` fail across the boundary; that broke the very tests that pin
the 402/409/406 copy above. Removing the test target's duplicate link (it gets the framework from the
app host, and `RenderAPITestSupport` already depends on it) fixed those tests and closes open item 7 —
app tests can now assert on a specific `RenderError` case.

#### Phase 5c — Postgres and Key Value ✅ CORE DONE

**Built:** `PostgresStore`/`PostgresListView`/`PostgresScreen`, `PostgresDetailStore`/
`PostgresDetailView`, `PostgresAction`, and the Key Value equivalents, plus a shared `DatastoreRow`,
in a new `App/Databases/`; two more tabs on `WorkspaceScreen`; `MetricsCatalog.charts(forPostgres:)`
and `charts(forKeyValue:)` with the active-connections chart Phase 4 had deferred;
`DatabaseStatus+Display`; `Scripts/widen-enums.py`; a read-only datastore section in
`Scripts/smoke.sh`. Both screens follow the `ServicesStore`/`ServiceDetailStore` pattern rather than
inventing a second one, and both detail screens reach the **existing** Logs and Metrics views — a
datastore is just another `resource` to `GET /logs`, so there was nothing to write.

**Decisions worth naming:**
1. **Separate tabs, not one "Datastores" list.** The two are different resources with different
   actions and different plans, and merging them would mean a row that has to explain which kind it
   is before it can say anything useful.
2. **Availability is computed, like every other action set.** Failover needs a standby to promote
   (HA on), a primary to promote from, and a database actually serving; a suspended database offers
   Resume and nothing else.
3. **Every banner says "requested".** All six lifecycle endpoints answer `202` — Render has accepted
   the intent, not finished the work — so the store polls the transitional status rather than
   claiming an outcome it hasn't seen.
4. **Who suspended it is shown next to the badge.** A billing suspension will not lift from this app,
   and finding that out by tapping Resume is worse than reading it.
5. **A failed connection-info call degrades that section only.** The credentials are a separate
   request from the database itself; blanking the whole screen because one of two calls failed would
   hide the status you opened the screen to read.
6. **Datastore charts are a fixed set, not type-driven.** Every Postgres has CPU, memory, and
   connections. Disk is the exception: flexible plans report no `diskSizeGB`, so there is nothing to
   chart against.

**Live pass: done, and the app didn't work.** Both tabs showed "Render returned data this version of
the app doesn't understand" in place of the entire list, against a real workspace. Three separate
spec-vs-reality mismatches, all with the same blast radius — the generated client decodes the whole
response before any domain mapping runs, so one legacy value in one row loses every row:
1. **`ipAllowList` is required and non-nullable in the spec; Render sends `null`** for a datastore
   with no rules, which is most of them — every Key Value instance in the sample workspace, and a
   fresh free-tier Postgres the moment it's created. Relaxed on all four schemas.
2. **`postgresDetail.project` is required and simply absent** on a database that isn't in a project.
3. **`postgres.plan` has no `starter_legacy`, and `postgresVersion` has no `10`.** Both are values
   Render no longer lets you create and still runs: **one 2018 database on Postgres 10 emptied a list
   of 42.**

The first two went through `relax-nullable.py`, which existed for exactly this. The enums needed
something new — `widen-enums.py`, additive and idempotent so a re-vendor keeps the fix and an
upstream addition isn't duplicated. **Widening rather than dropping the enum on purpose:** the
documented values are still worth having as a compile-time list, which the display code reads.
`DatastoreDecodeTests` pins all three against real trimmed payloads, through the real generated
client with only the transport stubbed — the same shape as `ServiceDetailsTests`, and for the same
reason: a hand-rolled decoder would faithfully agree with the spec and tell us nothing.

**Not built, and still 5c's scope:** Postgres recovery, credentials rotation, and the
top-queries / sizes / processes / table-scans diagnostics; projects and environments as manageable
resources rather than a scope filter; blueprints + syncs, disks + snapshots, webhooks, maintenance,
audit logs. Owner notification settings were 5c scope and landed with
[Phase 6](#phase-6--failure-notifications--done-device-local-half) instead, since that is the screen
someone opens to ask why they weren't told.

### OAuth sign-in ✅ DONE

Render's REST API authenticates with a static API key, but the dashboard and `render login` use an
RFC 8628 device-authorization flow — and asking someone to mint an API key on a laptop before they
can use a phone app is the wrong first screen. The device flow is now the default way in, with the
pasted key kept as a collapsed fallback (and the path CI, the smoke script, and the recorders use).

**Built:** `OAuth/` in `RenderAPI` — `RenderOAuthClient` (device grant, token poll, refresh, revoke),
`OAuthToken`, `OAuthHTTPTransport`, and `OAuthCredentialProvider`; `DeviceAuthorizationView` and
`OAuthEnvironment` in the app; `StubOAuthTransport` in the test support product;
`Scripts/record-walkthrough-oauth.sh`. Endpoint semantics are mirrored from the open-source CLI and
pinned by tests.

**Decisions worth naming:**
1. **It slots into the existing `APIKeyProvider` seam.** `OAuthCredentialProvider` returns a valid
   access token, refreshing before expiry, so `AuthMiddleware`, the generated client, and `LogStream`
   needed no changes at all. `AuthStore` holds one credential at a time; signing in one way clears
   the other.
2. **The provider is an actor, and there must be exactly one.** A refresh is shared state: when
   several requests hit an expired token at once, one refresh runs and everyone awaits it. A fresh
   instance per call site would defeat the coalescing, which is why `AuthStore` holds the one.
3. **A refresh token rejected outright routes back to onboarding** with a reason, rather than
   failing every screen individually.
4. **Sign-out revokes server-side, best-effort.** It must not block on — or fail with — the network.
5. **The endpoints take a JSON body under a `application/x-www-form-urlencoded` content type.** That
   is what the CLI sends and what Render accepts; it is mirrored exactly and pinned by a test,
   because it reads like a bug and would be "fixed" otherwise.
6. **The transport is its own seam**, like `LogStream`'s: these endpoints aren't in the OpenAPI spec,
   so the generated transport (keyed on operation IDs) doesn't fit.

**It prototypes with the Render CLI's `client_id`.** Render issues one per integration with no
self-serve registration, so sessions started this way appear as "Render CLI" in the dashboard, and
Render could rotate or re-scope that id at any time. See open item 11.

### Phase 6 — Polish

A UI pass landed ahead of the rest of this phase, on the grounds that an app that reads as a
wireframe is hard to judge and harder to hand to anyone:

- **The brand palette**, sampled from render.com's compiled CSS (the brand kit ships black-and-white
  artwork and no colour spec), wired as the global accent — which needs
  `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`, not a `.tint()`, to reach `UITabBar`. The dark
  accent is deliberately *lighter* than the light one.
- **A launch screen** carried into the first frame: `UILaunchScreen` and `SplashView` draw the same
  mark at the same size on the same colour, so the handoff has nothing to show. There is no build
  setting for `UILaunchScreen` (the `INFOPLIST_KEY_*` mechanism only emits top-level keys), so
  `Resources/Info.plist` holds that one dictionary and Xcode merges the generated keys into it.
- **An onboarding screen that says what the app does** — the mark on a gradient panel, a tagline,
  and three capability rows — carrying its `matchedGeometryEffect` id from the splash. This is the
  only place in the app that spends real colour; everything past sign-in is a dense operational list
  where a gradient is noise.
- **`SkeletonList` and `ErrorStateView`**: ghost rows shaped like the real ones instead of a spinner
  on a blank screen, and one error block in place of sixteen copies whose wording had already
  drifted. Skeletons are `accessibilityHidden` — placeholder shapes are not information.
- **Motion and haptics on caused state only**: chips pulse while something is still moving, action
  outcomes get a success/error haptic and a spring, metric headlines roll digit-by-digit. Charts
  gained a gradient area fill, drawn only for a single measurement series.
- **`StatusChip` and `Theme`**: the two status chips had become byte-for-byte identical views over
  two enums, and nine files carried inline geometry literals.

Still open in this phase:
- Widgets / Live Activity for an in-flight deploy.
- ~~Background refresh + local notifications on deploy failure~~ — **done**, see below. True push
  still needs a server to receive Render webhooks; the design for it is recorded there too.
- A full accessibility pass: Dynamic Type at the largest sizes, VoiceOver labels beyond the status
  chips' own prefixes.

#### Phase 6 — Failure notifications ✅ DONE (device-local half)

**Built:** `App/Notifications/` — `WatchlistStore`, `EventWatermarkStore`, `FailureWatcher`,
`NotificationScheduler`, `NotificationRouter`, `FailureWatchCoordinator`, `NotificationSettingsStore`
and `NotificationSettingsView`; a watch toggle on the service detail screen and a swipe action plus
bell glyph in the list; `UIBackgroundModes`/`BGTaskSchedulerPermittedIdentifiers` in
`Resources/Info.plist`. **No entitlement and no `.entitlements` file**: local notifications raised
after a `BGAppRefreshTask` need neither. `make check` green — 93 package tests, 225 app tests,
`BUILD SUCCEEDED` — and driven on the simulator against a real workspace.

**Decisions worth naming:**

1. **A watchlist, not every service.** There is no account-wide events feed in the API: the only
   listable event collections are per service, per webhook, and per task run. So "did anything
   break" costs one request per service, inside a background budget measured in seconds. The user
   picks up to 20.
2. **The poll is unfiltered.** `GET /services/{id}/events` takes `type` as a *single* value, not a
   list, so filtering server-side to the eight types worth alerting on would multiply requests by
   eight rather than divide them. One request per service since its watermark, filtered in
   `FailureWatcher`.
3. **`deploy_ended` costs a second request.** It can't say whether the deploy succeeded — that lives
   in `event.details`, the union the app can't decode (§F of `docs/api-accommodations.md`). So the
   status comes from `DeploysStore.latestDeploy`, and only when a deploy actually ended. Known
   imprecision, documented at the call site: it reads the *newest* deploy, so a failure immediately
   redeployed reports the redeploy. That errs toward not shouting about a superseded failure.
4. **The watermark is a timestamp *and* a bounded ID set.** `startTime` is inclusive and Render emits
   several events in the same second, so a timestamp alone either re-alerts on the boundary event
   forever or steps over its siblings. Both cases are pinned by tests.
5. **One credential provider per process** (`SharedCredentials`). `OAuthCredentialProvider` coalesces
   refreshes per instance; a background poll and a foreground screen refreshing the same rotating
   refresh token would sign the user out. `AuthStore` takes it via a new `shared:` parameter that
   defaults to `nil`, so tests keep their injected stores.
6. **The delegate uses the completion-handler methods, not the `async` ones.** Found by running it:
   the `async` spelling replies to UIKit's ObjC completion block from whatever executor the
   continuation resumed on, and UIKit asserts if that isn't the main thread. Every tapped
   notification crashed the app at launch, with a stack naming UIKit rather than the app.

**Not done — true push.** Still needs a server, for three independent reasons: APNs only accepts
pushes authenticated by a `.p8` key that can't ship in the app, a phone has no public URL for Render
to POST a webhook to, and Render's email/Slack channels can't target a device. The design agreed for
that follow-up: a **Go relay in a new top-level `Server/`** with its own `render.yaml`, kept out of
`make check`; the **app creates the webhook itself** via `POST /v1/webhooks` under the user's own
credential and hands the relay only the `secret` from the 201, so the relay never stores a Render
credential; device registration authenticates by proxy-verifying the caller against `GET /owners`,
persisting only `ownerId` + APNs token; and pushes stay **thin** (`mutable-content: 1`, enriched
on-device by a Notification Service Extension), so service names never sit in the relay's database.
That work also needs an APNs auth key, the first `.entitlements` file, and a Render-issued OAuth
client id (`OAuthEnvironment` still borrows the CLI's).

### Distribution

`make archive TEAM_ID=…` and `make ipa TEAM_ID=…` produce a signed device archive and a TestFlight-
ready `.ipa`, replacing a walk through the Organizer. Four things stood between the app and an
accepted upload, none of them functional:

1. **`PrivacyInfo.xcprivacy`.** `AuthStore` and `ProjectsStore` read `UserDefaults`, a required-reason
   API since May 2024; an upload without the declaration earns an ITMS-91053 rejection rather than a
   build. `App/` is a synchronized root group, so the file needs no project edit to reach the bundle.
   Nothing else touches a required-reason category and nothing leaves the device, so the tracking and
   collected-data sections are empty and should stay that way.
2. **`ITSAppUsesNonExemptEncryption = false`.** Otherwise Connect asks the encryption question on
   every build and holds it until someone answers. The app ships no cryptography of its own; it talks
   HTTPS to Render through `URLSession`, which is the exemption this key declares.
3. **`MARKETING_VERSION` 0.1 → 1.0**, with `CURRENT_PROJECT_VERSION` at 1 — right for a first upload,
   and it has to climb for every one after it.
4. **`TEAM_ID` as a make variable**, not a value in `project.pbxproj`, so a fresh clone doesn't try to
   sign against an account it can't reach; `Scripts/ExportOptions.plist` stays account-agnostic the
   same way, with the team stamped into a `build/` copy at run time. The export target is `ipa` and
   not `export` because `export` is a GNU make directive and a target sharing the name parses
   ambiguously.

Verified against a built bundle rather than the source: the manifest lands in `RenderiOS.app`, and
the merged `Info.plist` reads false / 1.0 / 1. **Signing still needs a Team ID and the bundle ID
still needs registering** — and see open item 2 before it goes anywhere public.

---

## Critical files

| File | Role |
|---|---|
| `Scripts/flatten-path-refs.py` | Makes the spec readable by OpenAPIKit at all; from `render-agent` |
| `Scripts/order-oneof.py` | Orders the `serviceDetails` `oneOf` so the first-match decoder can't misclassify a cron job |
| `Scripts/number-params.py` | Makes numeric query parameters serialize the way Render parses them — `resolutionSeconds=60`, not `60.0` |
| `Scripts/envelope-env-groups.py` | Gives `GET /env-groups` the cursor envelope it actually returns; without it the env group list decodes nothing |
| `Scripts/widen-enums.py` | Adds the plans and versions Render still runs but no longer documents — one legacy value empties a whole list |
| `Packages/RenderAPI/Sources/RenderAPI/NoContentWrite.swift` | Any 2xx is a success — three of this spec's write endpoints report success with a status they don't document |
| `Packages/RenderAPI/openapi.json` | The pinned, flattened contract; the single point of upstream drift |
| `Packages/RenderAPI/Sources/RenderAPI/ServiceDetails+Decode.swift` | Works around the undiscriminated `oneOf` — the highest-risk code in the app |
| `Packages/RenderAPI/Sources/RenderAPI/RetryMiddleware.swift` | 429 handling; the app polls, so this is load-bearing |
| `Packages/RenderAPI/Sources/RenderAPI/LogStream.swift` | One of two hand-written transports |
| `Packages/RenderAPI/Sources/RenderAPI/OAuth/OAuthCredentialProvider.swift` | The other; must be a single shared instance, or concurrent refreshes stop coalescing |
| `App/Auth/SharedCredentials.swift` | Holds that single instance. Background refresh gave the app a second entry point that could refresh a rotating token at the same time as a screen |
| `App/Notifications/EventWatermarkStore.swift` | Decides what has already been reported. Get it wrong and the app either alerts forever or goes silent |
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

**293 tests today: 93 in 14 suites (package) and 200 in 24 suites (app).**

*Package* (`Packages/RenderAPI/Tests`), fixture-driven `swift-testing` cases: `ServiceDetails`
decoding for all 5 service types, datastore decoding against real trimmed payloads, cursor
pagination termination, `RetryMiddleware` backoff on a stubbed 429 with `Retry-After`, `RenderError`
mapping for 401/403/404/429/5xx, the OAuth device flow and its refresh coalescing.

*App* (`AppTests/`, target `RenderiOSTests`): the `@Observable` stores, driven through the real
generated client with only the transport stubbed — so a test covers the query a store actually
builds, not a re-implementation of it. Since Phase 5b untangled the target's duplicate `RenderAPI`
link, these can assert on a specific `RenderError` case too.

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
match dashboard metrics; Phase 5a — an env var round-trips; Phase 5b — an env group round-trips
(create, add a variable, link, unlink, delete) and a custom domain is added, checked, and removed;
5c — both datastore lists load against a workspace with legacy databases in it, which is the case
that broke.

**The whole app on video:** `make walkthrough` records a scripted tour of every screen with
`Scripts/sim-input.swift` driving and `simctl io recordVideo` rolling, `make walkthrough-verify`
tiles one frame per beat so a swallowed tap can't pass as a completed tour, and
`make walkthrough-captions` burns the beats file in as subtitles. Nothing in the tour writes.
`Scripts/capture-screenshots.sh` re-shoots the README's stills from the same coordinates.

Driving the app now includes signing it in, since the Keychain starts empty on a fresh simulator:

```sh
swift Scripts/sim-input.swift tap 600 1035              # the API key field
printf '%s' "$RENDER_API_KEY" | swift Scripts/sim-input.swift type   # stdin, so it stays out of argv
swift Scripts/sim-input.swift press return
```

**One simulator per workspace, if another agent is working in parallel.** Every workspace builds the same
bundle ID, so a sibling's install replaces the app under your taps and `booted` stops meaning the device
you're watching. Give the pass its own device and name it in both places:

```sh
xcrun simctl create "bangui iPhone 17 Pro" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-26-5
Scripts/run-simulator.sh "bangui iPhone 17 Pro"
export SIM_DEVICE="bangui iPhone 17 Pro"          # sim-input + `simctl io "$SIM_DEVICE" screenshot`
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
   submission. Changing it now is cheap — two `PRODUCT_BUNDLE_IDENTIFIER` lines in the pbxproj — and
   it gets *more* expensive once a bundle ID is registered and a TestFlight build exists, which
   `make ipa` now makes easy to do. Decide before the first upload, not after.
3. **Generated-code size.** 6.6 MB / 141K lines committed, ~30s to compile clean. Acceptable, but
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
7. ~~**The app test target links `RenderAPI` twice.**~~ **Done in Phase 5b.** It caused exactly the
   subtler surprise it was flagged for: tests pinning the 402/409/406 copy on the new config screens
   failed because `error as? RenderError` returned nil across the boundary. Removing the test target's
   duplicate package link fixed them — the framework comes from the app host, and
   `RenderAPITestSupport` already depends on it.
8. ~~**The write side of header and route rules is untested live.**~~ **Done.** A scratch static site
   (`nextjs-static` in Patrick's Workspace) closed it: add, reorder, and delete were all driven from the
   app against a populated list and verified against the API, and the reorder's failure branch was
   exercised by deleting a rule behind the app's back. No app defects; four API findings and one
   simulator-isolation fix in the [edge-rule write pass](#edge-rule-write-pass--done).
9. **`GET /env-groups` needs a spec patch to decode at all.** `Scripts/envelope-env-groups.py` supplies
   the cursor envelope the live API sends and the spec omits. If Render ever ships the documented shape,
   `Scripts/smoke.sh` says so and the patch has to go.
10. **A failed write shows Render's raw message, and for a `404` that's just "Not found."** Seen live on
    a reorder whose rule had been deleted elsewhere. The list reloads correctly, so the state is right and
    only the sentence is thin; loads already get plain sentences for `406`/`410` via
    `ServiceConfigCatalog.loadFailureMessage`, and writes want the same treatment for `404` ("That rule no
    longer exists") and `409`. Not urgent — the banner is accurate, just terse.
11. **The OAuth flow runs on the Render CLI's `client_id`.** Render issues one id per integration and
    has no self-serve registration, so the prototype borrows the CLI's: sessions started from the app
    appear as "Render CLI" in the dashboard, and Render can rotate or re-scope that id without
    warning — at which point sign-in stops working for everyone. Needs an id issued for this app
    before it goes to anyone else, and it is the same conversation as open item 2.
12. **The config screens and datastore tabs have no screenshots.** `docs/screenshots/` covers the
    Services side only; the newer screens exist on video and nowhere still. `capture-screenshots.sh`
    is where the extra beats would go.
13. **Route priorities are Render's to renumber, and the app assumes otherwise in two small ways.**
    Deleting one rule shifted the others (1, 2, 9 → 2, 3, 10), relative order intact. So `add()`'s
    `max + 1` can be computed from a stale maximum and collide — which Render accepts, since it validates
    neither duplicate priorities nor duplicate sources — and `sortedRules`' `sorted { $0.priority <
    $1.priority }` gives no defined order for a tie. Reloading before an add, or breaking ties on ID,
    would make the screen deterministic. Nothing observed to be wrong today.
