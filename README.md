<img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" align="right" alt="App icon">

# Render for iOS

A native iPhone app for [Render](https://render.com) — on-call triage and one-tap recovery for your
services, without opening a laptop.

Sign in through Render's browser approval flow (or paste an API key), browse the services in any
workspace or project you belong to, drill into one to see its current deploy and configuration, walk
its deploy history and event timeline, and run the actions that matter at 3am: deploy, roll back,
cancel, restart, suspend/resume, scale, purge cache, trigger a cron job. Read its logs, live, and
chart its CPU, memory, HTTP traffic, latency, bandwidth, instances, and disk against the plan's
limits. Edit the configuration behind it — env vars, secret files, env groups, custom domains, and a
static site's redirects and headers — and deploy the change from the banner that confirms it. Your
Postgres databases and Key Value instances get their own tabs, with connection info, the same logs
and metrics screens, and their own lifecycle actions. Mark the services you care about and the phone
tells you when one of them breaks, then opens straight to it.

Built with SwiftUI, Swift 6 strict concurrency, and a code-generated client over Render's public
OpenAPI spec. No third-party UI or networking dependencies.

> **Status:** Phases 0–5b are complete (auth, service list, service detail, deploys, events,
> lifecycle actions, logs with a live WebSocket tail, metrics charts, and the full config surface),
> along with the core of 5c — the Postgres and Key Value tabs. Each was verified against a real
> workspace, config and datastore writes included. Failure notifications landed from Phase 6 —
> device-local, since true push needs a server. The app is prepared for TestFlight
> (`make ipa`), and what remains of parity — projects, blueprints, disks, webhooks, audit logs — is
> in [`PLAN.md`](PLAN.md) with the rest of the roadmap.

---

## Screenshots

| Onboarding | Service list | Service detail |
|---|---|---|
| ![Onboarding](docs/screenshots/onboarding.png) | ![Service list](docs/screenshots/services-list.png) | ![Service detail](docs/screenshots/service-detail.png) |
| Sign in through Render in the browser, or paste an API key from the collapsed fallback. Either credential is validated against `GET /owners` and stored in the Keychain — never in `UserDefaults`, never in the repo. | Every service in the active workspace/project, searchable and filterable by type, paging as you scroll. PR previews are excluded. | Current deploy status, then the configuration facts worth knowing on call, then drill-downs. |

| Actions | Deploy history | Deploy detail | Events |
|---|---|---|---|
| ![Actions menu](docs/screenshots/actions-menu.png) | ![Deploys](docs/screenshots/deploys.png) | ![Deploy detail](docs/screenshots/deploy-detail.png) | ![Events](docs/screenshots/events.png) |
| The action set is computed per service: an image-backed service gets "Deploy Latest Image" and no cache-clearing build; a cron job gets "Run Now". Every action is confirmed first. | Newest first, paging as you scroll. Roll back from a leading swipe — full-swipe is disabled deliberately, so a careless thumb can't fire one. | Status, trigger, timing, and the commit or image that shipped. Refetched on open so an in-flight deploy shows current status. | What Render did to this service and when. 42 event types, colour-coded by whether something broke, something is moving, or it's bookkeeping. |

| Metrics | HTTP metrics | Static site |
|---|---|---|
| ![Metrics](docs/screenshots/metrics.png) | ![HTTP metrics](docs/screenshots/metrics-http.png) | ![Static site metrics](docs/screenshots/metrics-static-site.png) |
| Up to twelve series fetched concurrently behind one spinner. Units come from the API, not from a table — and a limit too far above the readings to plot becomes a caption rather than flattening the line you came to read. | Requests grouped by status code, because the 3am question is how many failed. Latency at p50/p95/p99: a p50 alone hides the tail, a p99 alone can't say whether everything is slow or only a few things. | Charts are chosen per service type. A static site has no instance, so it has no CPU or memory — offering them would make "no data" ambiguous between *nothing happened* and *not applicable here*. |

| Logs | Live tail | Log filters |
|---|---|---|
| ![Logs](docs/screenshots/logs.png) | ![Live tail](docs/screenshots/logs-live.png) | ![Log filters](docs/screenshots/logs-filter.png) |
| Newest first, paging backwards through the window Render hands back. Severity down the left edge, request logs summarised as `POST 200 /webhook`. Tap a line for its full label set. | A WebSocket tail over `GET /logs/subscribe` — the one endpoint the generator can't express, so it's hand-written. Reconnects with backoff; pause holds lines without dropping them. | The filter set is server-side, and its vocabulary comes from `GET /logs/values` — so it offers the levels and types *this* service actually emits, not a hard-coded list. |

The set above is captured by `Scripts/capture-screenshots.sh`, which drives the same tour the
walkthrough recorder does and sources its coordinates — so a UI change is one command to re-shoot
rather than an afternoon of hand-captured stills that quietly drift a release behind. The config
screens and the two datastore tabs have no stills yet; they're covered in the
[walkthrough video](#recording-a-walkthrough).

---

## Getting started

**Requirements:** Xcode 26 (Swift 6), an iOS 18+ device or simulator, and a Render API key from
[dashboard.render.com/u/settings/api-keys](https://dashboard.render.com/u/settings/api-keys).

```sh
git clone <this repo>
cd render-ios
make run          # build, install, and launch on the iPhone 17 Pro simulator
```

Tap **Sign in with Render** and approve in the browser, or open the fallback and paste an API key.
Either credential is stored in the device Keychain and nowhere else.

```sh
make check        # everything CI runs: tests + build
make test         # both test suites
make test-package # RenderAPI package only — fast, no simulator
make test-app     # app-target store tests — needs a simulator
make build        # build for the simulator
make generate     # re-vendor the OpenAPI spec and regenerate the client
make drift        # regenerate and report whether Render changed the spec
make help         # list targets
```

`SIMULATOR="iPhone 17"` overrides the device for `run`/`build`/`test-app`.

### Distribution

```sh
make archive TEAM_ID=XXXXXXXXXX   # signed device archive
make ipa     TEAM_ID=XXXXXXXXXX   # …and export build/export/RenderiOS.ipa for TestFlight
```

`TEAM_ID` is your 10-character Apple Developer Team ID, and it is a make variable rather than a value
in `project.pbxproj` so a fresh clone doesn't try to sign against an account it can't reach —
`Scripts/ExportOptions.plist` stays account-agnostic the same way, with the team stamped into a
`build/` copy at run time. The target is `ipa` and not `export` because `export` is a GNU make
directive and a target sharing the name parses ambiguously. Bump `CURRENT_PROJECT_VERSION` before
each upload; build numbers must not repeat. The bundle ID still needs registering, and see the
trademark note at the end of [Design notes](#design-notes) before submitting anything.

### Optional: live smoke test

`Scripts/smoke.sh` exercises the real API read-only (owners, services, deploys, events, logs,
metrics, env vars, secret files, env groups, custom domains, routes, headers, Postgres, Key Value) so
you can confirm what the app should be showing — and it asserts the spec assumptions the
app is built on, so it's how you find out one stopped holding:

```sh
cp .env.example .env   # then paste your key into RENDER_API_KEY
Scripts/smoke.sh
```

`.env` is gitignored. Nothing in the repo, the tests, or CI ever holds a key — the app itself only
ever reads the one you type on-device.

---

## How the app works

### Three layers, one direction

```
┌──────────────────────────────────────────────────────────────────┐
│  SwiftUI views          ServicesListView, ServiceDetailView, …   │
│    ▲ reads domain structs, never generated types                 │
├──────────────────────────────────────────────────────────────────┤
│  @Observable stores     ServicesStore, ServiceDetailStore, …     │
│    ▲ maps generated types → ServiceSummary, DeploySummary, …     │
├──────────────────────────────────────────────────────────────────┤
│  RenderAPI package      RenderClient + middleware + Generated/   │
│    ▲ 207 operations generated from the vendored OpenAPI spec     │
└──────────────────────────────────────────────────────────────────┘
```

A view never touches a `Components.Schemas.*` type. Each store owns the mapping into a small
`Sendable` domain struct, so an upstream spec change is absorbed in one layer instead of rippling
through the UI.

The signed-in root is four tabs — Services, Postgres, Key Value, Env Groups — each with its own
navigation stack. `WorkspaceScreen` owns what belongs to the session rather than to a list: the scope
picker, the account menu, and the `ProjectsStore` behind them, so every tab agrees about the active
workspace and switching tabs doesn't re-fetch the project list. Env groups and datastores are tabs
rather than drill-downs because they belong to the *workspace*: there is no `GET
/services/{id}/env-groups` to hang one off.

### The API layer (`Packages/RenderAPI`)

A local SwiftPM package that is the app target's only dependency. `RenderClient` wraps the generated
client with a fixed base URL and a three-middleware stack — order matters, and it's outermost-first:

| Middleware | Job |
|---|---|
| `StatusMappingMiddleware` | Outermost, so it sees only the *final* response: turns a terminal 4xx/5xx into a thrown `RenderError`. |
| `RetryMiddleware` | Exponential backoff with jitter, honouring `Retry-After` on 429. A 429 is replayed for any method; a 5xx only for idempotent ones, so a failed `POST /deploys` can't ship twice. |
| `AuthMiddleware` | Attaches `Authorization: Bearer <credential>`, reading it per request so a sign-out, a token refresh, or a workspace switch takes effect immediately. |

Other pieces that earn their place:

- **`Keychain` / `KeychainAPIKeyProvider`** — credentials are the only secret, stored as generic
  passwords with `kSecAttrAccessibleAfterFirstUnlock`. Everything non-secret (selected workspace,
  selected project) lives in `UserDefaults`.
- **`OAuth/`** — Render's RFC 8628 device-authorization flow, the same one `render login` uses:
  request a grant, show the user code, poll until the browser approval lands.
  `OAuthCredentialProvider` is an actor behind the same `APIKeyProvider` seam the pasted key uses, so
  it refreshes an expired access token underneath the generated client and the log stream without
  either knowing it exists — and concurrent callers coalesce onto one refresh rather than racing.
  The endpoints have a quirk worth knowing: they take a **JSON body under a form-urlencoded
  content type**, which is what the CLI does and what Render accepts, so it's mirrored and pinned by
  a test.
- **`CursorPaginator`** — every Render list endpoint returns `{resource, cursor}` envelopes with no
  "hasMore" flag; a short page is the only end-of-collection signal. One generic `AsyncSequence`
  handles all of them, with both a `collect()` (drain everything) and a `firstPage(after:)`
  (page-on-scroll) mode.
- **`RenderDateTranscoder`** — Render sends microsecond-precision timestamps with a varying digit
  count, which `ISO8601DateFormatter` rejects outright. Without this, essentially every response
  fails to decode.
- **`RenderError`** — one enum (`unauthorized`, `forbidden`, `notFound`, `rateLimited(retryAfter:)`,
  `server`, `transport`, `decoding`) so views switch on intent, not on status numbers. Only
  `unauthorized` clears the stored credential.
- **`ServiceDetails+Decode`** — see [the `oneOf` problem](#the-oneof-problem) below.

### The stores

Each is `@MainActor @Observable`, owns exactly one screen's state, and is re-created when its scope
changes (SwiftUI `.id(...)` on the view).

| Store | Responsibility |
|---|---|
| `AuthStore` | Owns both ways in — the device flow and a pasted key, one credential at a time. Either is validated by calling `listOwners`: one round trip proves it works *and* yields the workspace list. A pasted key is written to the Keychain only *after* it validates, so a typo never displaces a working one. |
| `ProjectsStore` | Drains the owner's projects for the scope picker. Services belong to *environments*, not projects, so a project scope becomes an `environmentId` filter. A failure here is non-fatal — the list just stays workspace-wide. |
| `ServicesStore` | Pages the service list; search and type filtering are client-side over loaded pages. |
| `ServiceDetailStore` | Loads the service and its latest deploy concurrently, owns the lifecycle actions, and **polls while a deploy is in progress** — stopping the moment it settles, so an idle service costs zero requests. |
| `DeploysStore` | Pages deploy history; also the source of `latestDeploy` for the detail header. |
| `ServiceEventsStore` | Pages the event timeline **by time window, not cursor** — the events envelope declares a `cursor` it never defines, so the generator drops it. Each page asks for events older than the oldest one held, de-duplicated by ID. |
| `LogsStore` | Pages log history on the window Render hands back (`hasMore` + `nextStartTime`/`nextEndTime` — the one list endpoint that isn't cursor-based), and merges a live WebSocket tail into the same newest-first list. |
| `LogFilterValuesStore` | Fetches the filter vocabulary per facet from `GET /logs/values`, six calls concurrently. A facet that fails or comes back empty simply isn't offered. |
| `MetricsStore` | Fires up to twelve series requests **concurrently behind a single spinner** — there's no batch endpoint. A failed series fails its chart, not the screen; only a total failure takes over. |
| `EnvVarsStore` / `SecretFilesStore` | Read and write one set of variables or files, over an `EnvVarBackend` / `SecretFileBackend` — so the same store, views, editors, and masking serve both a service's config and an env group's. Writes address **one key at a time**, never the whole-list `PUT` that would delete whatever a teammate added since the screen loaded. |
| `EnvGroupsStore` / `EnvGroupDetailStore` | The workspace's env groups (drained, not paged: a partial list of shared config invites a duplicate) and one group's variables, files, rename, and service links. |
| `ServiceEnvGroupsStore` | The same links from the service's side — there is no `GET /services/{id}/env-groups`, so the link is found by reading each group's `serviceLinks`. |
| `CustomDomainsStore` | Add, verify, delete. Verification is reported as "checking", never as verified: `POST …/verify` answers `202` — it has queued a DNS check, not passed one. |
| `RouteRulesStore` / `HeaderRulesStore` | A static site's redirects/rewrites and headers. Routes are shown in evaluation order, and a reorder is two `PATCH`es — setting one priority alone would leave two rules claiming it. |
| `ConfigDeployer` | The deploy offered by a config success banner, so a saved change is one tap from running rather than two screens back. Shared by every config screen, using `ServiceAction.deploy`'s own confirmation copy so the two can't drift. |
| `PostgresStore` / `KeyValueStore` | Page the datastore lists for the active workspace, same shape as `ServicesStore`. |
| `PostgresDetailStore` / `KeyValueDetailStore` | Load the datastore and its connection info together, own the lifecycle actions, and **poll while the status is transitional**. A failed connection-info call says so in that section rather than blanking the screen. |
| `FailureWatcher` | Checks each watched service for something that broke since the last look, and returns alerts. One request per service, because there is no account-wide events feed — and unfiltered, because the `type` parameter takes a single event type rather than a list. One service failing never suppresses another's alert. |
| `WatchlistStore` / `EventWatermarkStore` | What this device watches, and how far each service's timeline has been examined. The watermark is a timestamp **and** a bounded set of event IDs: `startTime` is inclusive and Render emits several events in one second, so a timestamp alone either re-alerts on the boundary event forever or steps over its siblings. |
| `NotificationSettingsStore` | Render's own workspace settings — email, previews, `notificationsToSend` — written optimistically and put back if Render refuses. `slackEnabled` is read-only, because connecting Slack is an OAuth dance that happens in the dashboard. |

### Actions, and the care taken with them

`ServiceAction` is one enum carrying its own confirmation copy, because `Restart` and `Suspend` sit
one row apart in a menu:

- Availability is computed from the loaded service — cron jobs get "Run Now" instead of a deploy;
  cache purge and restart only appear for types that support them; an in-flight deploy adds "Cancel".
- Deploy wording follows the runtime: "Deploy Latest Commit" vs "Deploy Latest Image", because
  telling someone running an image-backed service that you'll build their branch is simply wrong.
- Every action is gated behind a confirmation dialog naming the service and what will happen.
- Rollback is offered only for deploys that actually shipped and aren't the one currently serving,
  and only via a swipe action with full-swipe disabled.
- Outcomes land in a bottom banner rather than an alert — the confirmation already happened, and a
  modal between two consecutive actions is friction for no safety gain.
- After any action, success or failure, the store reloads: these endpoints are asynchronous and the
  local copy is stale the moment they return.

`PostgresAction` (restart, fail over, suspend, resume) and `KeyValueAction` (suspend, resume) follow
the same contract for the same reason. All six endpoints answer `202`, so the banner says
"Restart requested." rather than claiming the work is done.

A config write says when it takes effect, which is not what the dashboard would have you assume:
**an API config write starts no deploy.** Render applies the change to the service's configuration
immediately and the running instances keep the old value until something else deploys them —
measured, not guessed. So every message on these screens says so, and a successful write offers
**Deploy Latest Commit** (or Image) right there in the banner. A group write doesn't: a group feeds
*N* services, so the honest thing is to name how many are waiting rather than fan out N deploys from
one tap.

### The generated client

`Packages/RenderAPI/Sources/RenderAPI/Generated/` is **committed** — 207 operations, ~141K lines,
produced by `swift-openapi-generator` from the vendored `openapi.json`. Committing it means an
upstream spec change arrives as a reviewable diff rather than a surprise build break, keeps clean
checkouts free of Xcode's plugin trust prompt, and keeps ~40s of generation off every incremental
build. `Package.resolved` pins the generator and runtime versions that produced it.

`RenderClient` exposes the generated client as `.api` rather than re-declaring 207 methods by hand;
the layer that earns its keep is the store that maps results into domain types.

---

## Working with the spec

Render publishes its OpenAPI spec unversioned and warns that it changes without notice. Six of its
properties actively break or degrade naive code generation, and `Scripts/generate-api.sh` works
around all six before the generator ever sees the file:

> The complete inventory of spec-vs-reality mismatches — every relaxed field, wrong status code,
> undocumented response shape, and behavioural surprise, with what each one broke — is in
> [`docs/api-accommodations.md`](docs/api-accommodations.md).

```
download → jq pretty-print → flatten-path-refs.py → relax-nullable.py → widen-enums.py
         → order-oneof.py → envelope-env-groups.py → number-params.py → generate
```

1. **Unresolvable `$ref`s.** OpenAPIKit only resolves refs into `#/components/…`, and the spec has
   ~250 refs into `#/paths/…`. `flatten-path-refs.py` inlines them. Without this, generation fails
   outright.
2. **Fields marked required that come back `null`.** The generated decoder is strict, so a single
   such field fails the *whole* response — `buildFilter.ignoredPaths` alone broke the service list
   on 66 of 190 real services. `relax-nullable.py` drops those from `required` so they generate as
   optionals. Each entry is a confirmed spec-vs-reality mismatch.
3. **Enums the live API overruns.** Render still runs resources on plans and versions it no longer
   lets you create, and an unlisted enum value fails the *whole* response the same way a null does:
   one 2018 database on `postgres_10` / `starter_legacy` emptied a list of 42. `widen-enums.py` adds
   the missing values, additively and idempotently, so a re-vendor keeps the fix and an upstream
   addition isn't duplicated. Widening rather than deleting the enum: the documented values are still
   worth having as a compile-time list, which the display code reads.
4. **<a id="the-oneof-problem"></a>`service.serviceDetails` is an undiscriminated `oneOf`.** The
   generated decoder tries each member in declaration order and keeps the first that succeeds — so
   the spec's ordering is load-bearing. `cronJobDetails`' requirements are a subset of
   `backgroundWorkerDetails`', which means every cron job would silently decode as a worker.
   `order-oneof.py` swaps them. On the Swift side, `ServiceDetails` reads every field keyed off the
   authoritative `service.type` and records which union member actually decoded, purely so a
   disagreement can be *detected* — the detail screen shows a warning banner rather than presenting
   possibly-wrong configuration as fact.
5. **`GET /env-groups` returns an envelope the spec doesn't describe.** The spec declares a bare array
   of `envGroupMeta`; the live API sends `{envGroup, cursor}` like every other list endpoint, which
   the strict decoder rejects outright — the env group list could not load a single real reply.
   `envelope-env-groups.py` synthesises the envelope schema and points the operation at it, which
   also makes the store an ordinary `CursorPaginator`. `Scripts/smoke.sh` fails loudly if the
   envelope ever disappears.
6. **Numeric query parameters that don't serialize the way Render parses them.** Every numeric query
   parameter is typed `number`, which the generator maps to `Double` — so `resolutionSeconds` went out as
   `60.0` and Render answered `could not parse input 60.0 for field resolutionSeconds`. That 400'd
   *every* metrics chart, and only the live pass caught it: the unit test had pinned `60.0` as if it were
   correct. `number-params.py` retypes it as `integer`, and separately drops `format: float` from
   `/metrics/http-latency`'s `quantile` — mapped to `Float`, whose serialization widens to
   `0.949999988079071` before printing, which is not reliably a request for the p95.

Consequences worth knowing before extending the app:

- **Service event details are not readable.** `serviceEvent.details` is a 44-member undiscriminated
  `oneOf` whose second member has *no* required properties, so it matches almost anything and reports
  success. `ServiceEvent` therefore carries only `type` and `timestamp`. (The upside: the union can
  never fail, so events always load.) Making details usable needs a spec patch.
- **The metrics endpoints drop the *datapoint* `unit`.** It appears in `required` but not in
  `properties`, so the generator skips it. The series-level `unit` beside it is well-formed, though,
  which is the one that matters — `MetricUnit(apiUnit:)` maps what Render reports (`cpu`, `bytes`,
  `seconds`, `unitless`, `mb`) rather than hard-coding a unit per endpoint, and renders an unrecognized
  one verbatim instead of guessing.
- **Each metrics response has its own generated type.** None of the fourteen `/metrics/*` schemas is a
  named component, so the generator emits fourteen unrelated copies of `{labels, values, unit}` (and
  fourteen unrelated query types). `MetricSeries` is the single type the app sees; the collapse is a
  protocol whose requirements are spelled with the generated property names, so all forty-two
  conformances are *empty* — nothing to keep in sync, and a compile error rather than a blank chart if
  a spec change moves a field.
- **A write can succeed with a status it doesn't document.** A secret file `PUT` answers 200 where the
  spec says 201; unlinking an env group answers 200 where it says 204 — and the generated accessor
  throws on anything undocumented, so the app reported a failure over work Render had already done.
  `NoContentWrite` treats **any 2xx** as success for the no-body writes, and three tests pin it,
  including that a real failure is still a failure.

`.github/workflows/spec-drift.yml` re-runs generation against the live spec every Monday and fails
when the committed output no longer matches. The fix is `make generate` and a review of the diff.

---

## Repository layout

```
App/                      app target (Xcode 26 synchronized folders)
  Assets.xcassets/        app icon and marks, brand palette (light / dark / tinted)
  PrivacyInfo.xcprivacy   required-reason API declaration (UserDefaults), no tracking, no collection
  Auth/                   onboarding, the device-flow screen, AuthStore
  Workspaces/             the tab bar, workspace + project scope picker, account menu
  Projects/               ProjectsStore
  Services/               list, detail, actions, events
  Deploys/                history, detail, rollback
  Logs/                   history, live tail, server-side filter sheet
  Metrics/                charts, range picker, unit formatting, per-type catalog
  Config/                 env vars, secret files, env groups, domains, routes, headers
  Databases/              Postgres and Key Value: lists, details, connection info, actions
  Notifications/          watchlist, watermarks, the failure poll, and Render's own notification settings
  DesignSystem/           status chips, glyph tiles, skeletons, error state, Theme, splash
AppTests/                 store tests, transport stubbed
Packages/RenderAPI/       the only dependency surface
  openapi.json            vendored + pinned, post-flatten
  Sources/RenderAPI/
    Generated/            committed generator output
    RenderClient.swift    façade: base URL + middleware stack
    *Middleware.swift     auth, retry, status mapping
    Pagination.swift      generic cursor AsyncSequence
    NoContentWrite.swift  any 2xx is a success for a no-body write
    ServiceDetails+Decode.swift   the oneOf workaround
    LogQuery/LogStream.swift      one filter description, two transports (one hand-written)
    MetricSeries*/MetricsQuery.swift   one series type and one window for 14 endpoints
    OAuth/                device flow, token storage, refreshing credential provider
  Sources/RenderAPITestSupport/   StubTransport and friends, shared by both suites
  Tests/RenderAPITests/
Resources/Info.plist      UILaunchScreen only — merged into the generated Info.plist
Scripts/                  generation pipeline, smoke test, simulator driver, recorders, icon builder
docs/api-accommodations.md   every spec-vs-reality mismatch found so far
docs/screenshots/
Makefile
PLAN.md                   design rationale, roadmap, and phase outcomes
```

---

## Testing

318 tests, all offline. `make test` runs both suites.

**`Packages/RenderAPI/Tests`** — 93 `swift-testing` cases in 14 suites over `StubTransport`:
`ServiceDetails` decoding for all five service types, datastore decoding against real trimmed
payloads, pagination termination, retry backoff on a stubbed 429 with `Retry-After`, `RenderError`
mapping for 401/403/404/429/5xx, date transcoding, the OAuth device flow and its refresh coalescing.
No simulator, no network.

**`AppTests/`** — 225 cases in 27 suites: the `@Observable` stores driven through the *real*
generated client with only the transport stubbed, so a test covers the query a store actually builds
rather than a re-implementation of it. The failure-watch suites are routed by request path rather
than by arrival order, because that watcher checks services concurrently — "the second response"
would be a race, not a fact.

No test makes a live call: an API key is a user secret and CI runs offline. The stub transport ships
as a package *product* (`RenderAPITestSupport`) because both suites need it.

Running the app tests needs a concrete simulator (`generic/platform=iOS Simulator` builds but can't
run), so `Scripts/test-destination.sh` resolves one at run time rather than pinning a device a CI
image may stop shipping.

CI (`.github/workflows/ci.yml`) runs the package tests, the app tests, and a simulator build on every
PR and every push to `main`, through the same `make` targets used locally.

### UI tests (headless)

`UITests/` holds XCUITest tests that sign in with the key in `.env`, walk real screens and save
screenshots. They run without the Simulator window and never touch the Mac's mouse or keyboard, so
you can keep working while they run. They reach the live API, so CI and `make test` skip them; they
have their own scheme, `RenderiOSUITests`.

```sh
make ui-test                              # every UI test; screenshots in build/ui-tests/screens
make ui-test ONLY=ServiceScreensTests     # one class, or Class/testMethod
make ui-test TEXT_SIZE=AccessibilityM     # at a Dynamic Type size
make ui-test UI_SERVICE=my-api            # UI_* variables reach the tests via AppDriver.value
make ui-test ONLY=WorkflowScreensTests UI_WORKFLOW=my-workflow UI_TASK=square UI_FLOW=my_flow
make ui-test UI_ALLOW_WRITES=1            # also run tests that change things (start task and flow runs)
```

The simulator's Keychain is reset first, so every run starts signed out with the current key.
Tests that change anything skip themselves unless `UI_ALLOW_WRITES=1` is set; only use it with a
key for a workspace that's safe to write to.

### Driving the simulator

Screens can also be exercised end-to-end with real mouse events. This brings the Simulator window to
the front and moves the cursor, so prefer `make ui-test` for anything new:

```sh
make run
swift Scripts/sim-input.swift tap 600 1349     # coordinates read straight off a screenshot
swift Scripts/sim-input.swift drag 600 2200 600 1200
swift Scripts/sim-input.swift press return
xcrun simctl io booted screenshot /tmp/step.png
```

Signing in is part of it, since a fresh simulator's Keychain is empty. Pipe the key rather than passing
it as an argument, so it stays out of argv and the shell history:

```sh
printf '%s' "$RENDER_API_KEY" | swift Scripts/sim-input.swift type
```

Both failure modes are silent, so check them first: the calling process needs **Accessibility**
permission, and the **Mac must be unlocked with an awake display**. With more than one simulator
booted, set `SIM_DEVICE` to the device name — otherwise the script stops rather than guess which
window to drive.

### Recording a walkthrough

The same driver, with `simctl io recordVideo` rolling, produces a video tour of the app:

```sh
make walkthrough                        # docs/walkthrough.mov, signs in with the key in .env
SERVICE=my-api make walkthrough         # tour a different web service
STATIC_SERVICE=my-site make walkthrough # and a different static site
make walkthrough-oauth                  # the same tour, through the OAuth device flow
```

The tour is about six minutes and covers every screen: the list and its workspace/project scope, a
web service in full (deploys, logs and the live tail, metrics, events, environment, secret files, env
groups, custom domains), then a static site for the two drill-downs only it has — redirects and
headers — then the Postgres and Key Value tabs, the workspace's env groups, and signing out. It needs
**two** services to do that, which is why `SERVICE` and `STATIC_SERVICE` are separate.

**Nothing in it writes.** Every tap navigates or opens something that is then cancelled, so it is safe
to point at a workspace you can't afford to change. The datastore action menus are the one thing it
deliberately never opens: on Postgres and Key Value the destructive item renders directly under the
toolbar, close enough that a mistimed dismiss tap could suspend a real database.

Each run reinstalls with the Keychain wiped so the tour starts from onboarding — without that, iOS
restores the last screen on launch and a blind coordinate script drifts. Alongside the movie it
writes a `.txt` of timestamped beats: `simctl` records no audio, so that is the narration script.

A blind coordinate script fails quietly — a single swallowed tap aims every later tap at the wrong
screen while the console still prints the whole tour — so check the result before publishing it:

```sh
make walkthrough-verify                 # one frame per beat, tiled, in .context/verify/
```

Each frame should show the screen its caption describes. A leg of the tour went missing this way once
already, from one second of settle after a scroll instead of two.

To put the two together:

```sh
make walkthrough-captions               # docs/walkthrough-captioned.mp4, subtitles burned in
PRESET=veryfast CRF=28 make walkthrough-captions   # a quick proof before the good encode
```

`Scripts/beats-to-srt.py` converts the beats file to SRT — each cue runs until the next beat starts,
since the recorder writes start times only — and `Scripts/burn-captions.sh` hard-subs it with libass.
Cue times are wall-clock and **the recording's clock is not wall time**: `simctl` timestamps frames by
when the screen changed and never pads the gaps, so a still simulator recorded for twenty seconds
writes a *0.07-second* movie. Every pause in the tour is squeezed out of the timeline, which leaves
cues running a few seconds behind the picture. The script corrects the total from the tour's wall
duration, but the squeeze isn't evenly spread, so check the alignment rather than assume it.
Hard subs rather than a `mov_text` track because a README, a PR, and Slack all render video without
subtitle controls, so a soft track is invisible exactly where it's wanted. **Homebrew's plain
`ffmpeg` bottle has no libass**: the `subtitles` filter is missing and the parser reports it as
`No option name near '<file>'`, which reads like a quoting bug. `brew install ffmpeg-full` provides a
build that has it, and the script finds it.

The OAuth variant stops and waits for you to approve in a browser, because that step is a human by
design. By default you approve on the Mac and the recording only ever shows the code and the
spinner; `OPEN_IN_SIM=1` puts the whole approval in the simulator's Safari instead.

Two things worth knowing before publishing a recording. It shows **real data** — workspace name,
service names, env var names and values, log lines, request paths — so point it at a workspace you're
willing to publish. And the coordinates were read off an **iPhone 17 Pro**; another device size needs
a fresh pass, and so does a service type whose drill-down list is a different length than the web
service and static site the tour expects.

---

## Design notes

- **iOS 18.0 deployment target**, not iOS 26. Nothing here needs an iOS 26-only API, and an on-call
  utility is worth less if it won't install on the phone you already have.
- **PR previews are excluded** from the service list by default — on a busy account they drown out
  the services this view exists for.
- **Errors are inline and actionable**, not alert spam: a failed list offers Retry in a
  `ContentUnavailableView`; a failed deploy-status fetch says "status unavailable" rather than
  implying the service never deployed.
- **Polling is opt-out by design**: only an in-flight deploy — or a datastore mid-restart — is
  polled, and it stops on its own when the status settles or the screen disappears.
- **Loading looks like the thing that's arriving.** A first page draws skeleton rows shaped like the
  real ones instead of a spinner on a blank screen, so the layout doesn't jump when the rows land;
  the skeletons are `accessibilityHidden`, because placeholder shapes are not information. The "couldn't
  load" block is one `ErrorStateView` rather than the sixteen copies whose wording had already drifted.
- **Motion and haptics only on state the user caused**, or state the server is actively changing: a
  status chip pulses while a deploy is building or a database restarting, an action outcome gets a
  success/error haptic, a metric headline rolls digit-by-digit. Nothing animates on its own.
- **The launch screen carries into the first frame.** `UILaunchScreen` draws the logomark on the brand
  violet and `SplashView` reproduces it exactly — same mark, same size, same colour — so the handoff
  has nothing to show. `matchedGeometryEffect` can't span it (the launch screen is a process-owned
  UIKit view, torn down before SwiftUI renders), which is why reproduction is the mechanism. The splash
  has a 700ms *floor*, not a delay: the restore and the sleep race, so only a fast restore waits.
- **Every branded asset comes out of the brand kit**, rendered by
  `Scripts/make-brand-assets.swift`. The source art floats off-centre in a much larger canvas, so
  the script measures the alpha bounding box and re-centres rather than scaling the file as-is. It
  writes the `Contents.json` files too, so a refresh can't leave them drifting. One command:

  ```sh
  swift Scripts/make-brand-assets.swift "<brand kit>/Logos"
  ```

  | Output | Rendering | Size |
  |---|---|---|
  | `AppIcon.appiconset` | black-on-white, plus transparent white marks for dark and tinted | 1024 |
  | `Logomark.imageset` | template | 120pt |
  | `Wordmark.imageset` | template | 160pt |
  | `LaunchLogomark.imageset` | **original** | 96pt |

  A *template* asset keeps only alpha, so one white source renders correctly in light mode, dark
  mode, tinted, and knocked out of the violet hero. The launch screen is the exception both ways:
  it runs before any app code, so there is no tint to apply, and `UILaunchScreen` draws its image
  centred at natural point size and **never scales it** — hence a separate non-template set
  authored at exactly the 96pt it should appear.

- **The brand palette is sampled from render.com**, not the brand kit, which ships black-and-white
  artwork and no colour spec. `AccentColor` is `#8A05FF` (their `--color-purple-600`), lightened to
  `#AA77FD` in dark mode — the saturated violet loses against near-black, and the tab bar's
  selected item is where that shows first. Setting an `AccentColor` colorset is not enough on its
  own; `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME` has no default and is what actually reaches
  `UITabBar`.

- **The bundle declares what App Store Connect asks about.** `PrivacyInfo.xcprivacy` declares the one
  required-reason API the app uses (`UserDefaults`, for the selected workspace and project); the
  tracking and collected-data sections are empty and should stay that way, since nothing leaves the
  device except calls to Render. `ITSAppUsesNonExemptEncryption` is `false` — the app ships no
  cryptography of its own and talks HTTPS through `URLSession` — which is what keeps Connect from
  holding every build on an unanswered encryption question.

- **"Render" is a third-party trademark**, logomark included. The bundle identifier is
  `com.veverkap.RenderiOS`; this is fine for personal use but both the name and the mark want
  sorting out before any App Store submission. The OAuth flow is on borrowed credentials for the same
  reason: it prototypes with the **Render CLI's** `client_id`, since Render issues one per
  integration with no self-serve registration — so sessions show up as "Render CLI" in the dashboard,
  and the app needs an id of its own before it ships to anyone else.

See [`PLAN.md`](PLAN.md) for the full rationale, what's left of parity (projects, blueprints, disks,
webhooks, audit logs), and per-phase verification records.
