import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("FailureWatcher")
struct FailureWatcherTests {
    // `nonisolated` because the routing closures are `@Sendable` and read them off the main actor.
    private nonisolated static let watchedAt = Date(timeIntervalSince1970: 1_770_000_000)
    private nonisolated static let eventTime = "2026-08-12T10:00:00Z"
    private nonisolated static let laterEventTime = "2026-08-12T10:05:00Z"

    /// A watcher over the named services, each already stamped as examined — which is the state
    /// after the user turns watching on. Routing by path rather than by arrival order because the
    /// watcher checks services concurrently, so "the second body" would be a race.
    private func makeWatcher(
        watching services: [(id: String, name: String)] = [(id: "srv-1", name: "api")],
        stampWatermarks: Bool = true,
        pageLimit: Int = 100,
        maxPages: Int = 3,
        route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (watcher: FailureWatcher, watchlist: WatchlistStore, watermarks: EventWatermarkStore) {
        let watchlist = WatchlistStore(defaults: makeTestDefaults())
        let watermarks = EventWatermarkStore(defaults: makeTestDefaults())
        for service in services {
            watchlist.add(id: service.id, ownerID: Fixtures.ownerID, name: service.name)
            if stampWatermarks {
                watermarks.begin(serviceID: service.id, at: Self.watchedAt)
            }
        }
        let (client, _) = RenderClient.routed(route: route)
        let watcher = FailureWatcher(
            client: client,
            watchlist: watchlist,
            watermarks: watermarks,
            now: { Self.watchedAt },
            pageLimit: pageLimit,
            maxPages: maxPages
        )
        return (watcher, watchlist, watermarks)
    }

    /// Answers the events endpoint with `events` and the deploys endpoint with `deploys`.
    private static func route(
        events: String,
        deploys: String = Fixtures.deploysPage([(id: "dep-1", status: "live")])
    ) -> @Sendable (String) -> (status: Int, body: String) {
        { path in
            if path.contains("/events") { return (200, events) }
            if path.contains("/deploys") { return (200, deploys) }
            return (404, "{}")
        }
    }

    // MARK: - Classification

    @Test("an event whose type is the whole story alerts on the type alone")
    func selfDescribingFailure() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([(id: "evt-1", type: "server_failed", timestamp: Self.eventTime)])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.count == 1)
        #expect(alerts.first?.serviceID == "srv-1")
        #expect(alerts.first?.serviceName == "api")
        #expect(alerts.first?.summary == "Server failed")
    }

    @Test("a disk filling up alerts; its recovery does not")
    func diskUsageHighAlerts() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([
                (id: "evt-1", type: "service_disk_usage_high", timestamp: Self.eventTime),
                (id: "evt-2", type: "service_disk_usage_recovered", timestamp: Self.eventTime),
            ])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.count == 1)
        #expect(alerts.first?.id == "evt-1")
        #expect(alerts.first?.summary == "Disk usage high")
    }

    @Test("bookkeeping events are not failures")
    func nonFailureEventsIgnored() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([
                (id: "evt-1", type: "build_started", timestamp: Self.eventTime),
                (id: "evt-2", type: "server_available", timestamp: Self.eventTime),
                (id: "evt-3", type: "plan_changed", timestamp: Self.eventTime),
            ])
        ))

        #expect(await watcher.poll().isEmpty)
    }

    @Test("deploy_ended alone is not a failure — the deploy's status decides")
    func deployEndedSucceeded() async throws {
        // The event says a deploy finished, not that it failed; `details` can't be read to find out,
        // so the deploy list is what answers.
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([(id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime)]),
            deploys: Fixtures.deploysPage([(id: "dep-1", status: "live")])
        ))

        #expect(await watcher.poll().isEmpty)
    }

    @Test("deploy_ended on a failed deploy alerts, keyed on the deploy")
    func deployEndedFailed() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([(id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime)]),
            deploys: Fixtures.deploysPage([(id: "dep-9", status: "build_failed")])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.count == 1)
        #expect(alerts.first?.summary == "Build failed")
        // Keyed on the deploy, not the event, so a window holding two `deploy_ended` events that
        // resolve to one deploy reports once.
        #expect(alerts.first?.id == "deploy-dep-9")
    }

    @Test("two deploy_ended events in one window report the one deploy once")
    func repeatedDeployEndedCollapses() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([
                (id: "evt-2", type: "deploy_ended", timestamp: Self.laterEventTime),
                (id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime),
            ]),
            deploys: Fixtures.deploysPage([(id: "dep-9", status: "update_failed")])
        ))

        #expect(await watcher.poll().count == 1)
    }

    // MARK: - Reading the cause from details

    /// Routes `/deploys` to a 500, so any test that passes proves the deploy list was never asked.
    private static func routeWithoutDeployList(events: String) -> @Sendable (String) -> (status: Int, body: String) {
        { path in path.contains("/events") ? (200, events) : (500, "{}") }
    }

    @Test("a failed deploy_ended answers from its own details, with the cause, and opens on the event")
    func deployEndedFromDetails() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.routeWithoutDeployList(
            events: Fixtures.eventsPage(withDetails: [(
                id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime,
                details: #"{"deployId":"dep-7","deployStatus":"failed","reason":{"failure":{"evicted":false,"oomKilled":{"memoryLimit":"512Mi"}}},"status":4}"#
            )])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.count == 1)
        #expect(alerts.first?.id == "deploy-dep-7")
        #expect(alerts.first?.summary == "Deploy failed: Out of memory (512Mi limit)")
        #expect(alerts.first?.eventID == "evt-1")
    }

    @Test("a succeeded deploy_ended is quiet without a deploy lookup")
    func deployEndedSucceededFromDetails() async throws {
        let (watcher, _, watermarks) = makeWatcher(route: Self.routeWithoutDeployList(
            events: Fixtures.eventsPage(withDetails: [(
                id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime,
                details: #"{"deployId":"dep-7","deployStatus":"succeeded","reason":{},"status":2}"#
            )])
        ))

        #expect(await watcher.poll().isEmpty)
        // Resolved, not "couldn't find out": the window is banked.
        #expect(watermarks["srv-1"]?.hasSeen("evt-1") == true)
    }

    @Test("the event's own deploy is reported, not the newest one")
    func deployEndedNotSuperseded() async throws {
        // The fallback would read the newest deploy — live — and stay quiet about this failure.
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage(withDetails: [(
                id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime,
                details: #"{"deployId":"dep-old","deployStatus":"failed","reason":{"buildFailed":{"id":"bld-1"}}}"#
            )]),
            deploys: Fixtures.deploysPage([(id: "dep-new", status: "live")])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.map(\.id) == ["deploy-dep-old"])
        #expect(alerts.first?.summary == "Build failed")
    }

    @Test("a self-describing failure gains its cause")
    func serverFailedWithCause() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage(withDetails: [(
                id: "evt-1", type: "server_failed", timestamp: Self.eventTime,
                details: #"{"instanceID":"srv-1-abc","reason":{"evicted":false,"nonZeroExit":1}}"#
            )])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.first?.summary == "Server failed: Exited with status 1")
        #expect(alerts.first?.eventID == "evt-1")
    }

    @Test("an image pull failure's alert carries Render's message")
    func imagePullFailedWithMessage() async throws {
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage(withDetails: [(
                id: "evt-1", type: "image_pull_failed", timestamp: Self.eventTime,
                details: #"{"imageURL":"docker.io/acme/api:latest","message":"pull access denied"}"#
            )])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.first?.summary == "Image pull failed: pull access denied")
    }

    @Test("two events about one failed deploy report it once")
    func deployDetailsCollapse() async throws {
        let details = #"{"deployId":"dep-7","deployStatus":"failed","reason":{},"status":4}"#
        let (watcher, _, _) = makeWatcher(route: Self.routeWithoutDeployList(
            events: Fixtures.eventsPage(withDetails: [
                (id: "evt-2", type: "deploy_ended", timestamp: Self.laterEventTime, details: details),
                (id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime, details: details),
            ])
        ))

        let alerts = await watcher.poll()

        #expect(alerts.count == 1)
        #expect(alerts.first?.summary == "Deploy failed")
    }

    // MARK: - Not saying it twice

    @Test("an event seen in one poll is not reported again in the next")
    func watermarkSuppressesRepeat() async throws {
        // The same body both times, which is what the inclusive `startTime` produces in practice:
        // the boundary event comes back on every poll.
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([(id: "evt-1", type: "server_failed", timestamp: Self.eventTime)])
        ))

        #expect(await watcher.poll().count == 1)
        #expect(await watcher.poll().isEmpty)
    }

    @Test("events sharing a timestamp all alert, and none of them repeats")
    func siblingTimestampsBothAlert() async throws {
        // The case a timestamp-only watermark can't get right: advancing to the timestamp re-alerts
        // forever, advancing past it drops the sibling. The ID set is what makes both work.
        let (watcher, _, _) = makeWatcher(route: Self.route(
            events: Fixtures.eventsPage([
                (id: "evt-1", type: "server_failed", timestamp: Self.eventTime),
                (id: "evt-2", type: "image_pull_failed", timestamp: Self.eventTime),
            ])
        ))

        let first = await watcher.poll()

        #expect(first.count == 2)
        #expect(Set(first.map(\.id)) == ["evt-1", "evt-2"])
        #expect(await watcher.poll().isEmpty)
    }

    @Test("a service watched for the first time reports nothing and starts its clock")
    func firstSightingReportsNothing() async throws {
        // No watermark, so this poll is the one that establishes one. Turning watching on must not
        // announce a failure that already happened and was already dealt with.
        let (watcher, _, watermarks) = makeWatcher(
            stampWatermarks: false,
            route: Self.route(
                events: Fixtures.eventsPage([(id: "evt-1", type: "server_failed", timestamp: Self.eventTime)])
            )
        )

        #expect(await watcher.poll().isEmpty)
        #expect(watermarks["srv-1"]?.lastSeen == Self.watchedAt)
    }

    // MARK: - Failure isolation

    @Test("one service failing doesn't suppress another's alert")
    func oneServiceErroringIsIsolated() async throws {
        let (watcher, _, _) = makeWatcher(
            watching: [(id: "srv-1", name: "api"), (id: "srv-2", name: "worker")],
            route: { path in
                if path.contains("srv-1") { return (500, "{}") }
                if path.contains("/events") {
                    return (200, Fixtures.eventsPage([(id: "evt-2", type: "server_failed", timestamp: Self.eventTime)]))
                }
                return (200, Fixtures.deploysPage([(id: "dep-1", status: "live")]))
            }
        )

        let alerts = await watcher.poll()

        #expect(alerts.map(\.serviceName) == ["worker"])
    }

    @Test("a failed check leaves the watermark alone so the next poll re-examines the window")
    func failedCheckDoesNotAdvanceWatermark() async throws {
        let (watcher, _, watermarks) = makeWatcher(route: { _ in (500, "{}") })

        #expect(await watcher.poll().isEmpty)
        #expect(watermarks["srv-1"]?.lastSeen == Self.watchedAt)
        #expect(watermarks["srv-1"]?.recentIDs.isEmpty == true)
    }

    @Test("a deploy_ended whose outcome couldn't be looked up is left unexamined")
    func unresolvedDeployDoesNotAdvanceWatermark() async throws {
        // The events request answered, so the naive thing is to bank it and move on — which throws
        // away the one event whose meaning is still unknown. "That deploy was fine" and "couldn't
        // find out" have to be told apart; only the first is allowed to advance the watermark.
        // Matters most under a cancelled background wake, where the second request is the one that
        // loses the race.
        let (watcher, _, watermarks) = makeWatcher(route: { path in
            if path.contains("/deploys") { return (500, "{}") }
            return (200, Fixtures.eventsPage([(id: "evt-1", type: "deploy_ended", timestamp: Self.eventTime)]))
        })

        #expect(await watcher.poll().isEmpty)
        #expect(watermarks["srv-1"]?.lastSeen == Self.watchedAt)
        #expect(watermarks["srv-1"]?.recentIDs.isEmpty == true)
    }

    @Test("a self-describing failure alongside an unresolved deploy is still re-examined")
    func unresolvedDeployHoldsBackItsSiblings() async throws {
        // Deliberately all-or-nothing per service: re-reporting `server_failed` on the next wake
        // only replaces a notification that's already on screen (the ID is the event's), whereas
        // banking the window would lose the deploy outcome permanently.
        let (watcher, _, watermarks) = makeWatcher(route: { path in
            if path.contains("/deploys") { return (500, "{}") }
            return (200, Fixtures.eventsPage([
                (id: "evt-2", type: "deploy_ended", timestamp: Self.laterEventTime),
                (id: "evt-1", type: "server_failed", timestamp: Self.eventTime),
            ]))
        })

        #expect(await watcher.poll().isEmpty)
        #expect(watermarks["srv-1"]?.lastSeen == Self.watchedAt)
    }

    // MARK: - Watchlist

    @Test("an un-watched service is not polled, and its watermark is dropped")
    func unwatchedServiceIsNotPolled() async throws {
        let (watcher, watchlist, watermarks) = makeWatcher(
            watching: [(id: "srv-1", name: "api"), (id: "srv-2", name: "worker")],
            route: Self.route(
                events: Fixtures.eventsPage([(id: "evt-1", type: "server_failed", timestamp: Self.eventTime)])
            )
        )
        watchlist.remove(id: "srv-1")

        let alerts = await watcher.poll()

        #expect(alerts.map(\.serviceName) == ["worker"])
        // Pruned rather than left behind: a stale watermark would silently suppress the first alert
        // if the service were ever watched again.
        #expect(watermarks["srv-1"] == nil)
    }

    @Test("an empty watchlist costs no requests")
    func emptyWatchlistDoesNothing() async throws {
        let watchlist = WatchlistStore(defaults: makeTestDefaults())
        let (client, transport) = RenderClient.routed { _ in (500, "{}") }
        let watcher = FailureWatcher(
            client: client,
            watchlist: watchlist,
            watermarks: EventWatermarkStore(defaults: makeTestDefaults())
        )

        #expect(await watcher.poll().isEmpty)
        #expect(transport.requests.isEmpty)
    }

    // MARK: - Windows too big for one page

    @Test("a full page is paged past, not treated as the whole window")
    func fullPagePagesBackwards() async throws {
        // The endpoint returns the *newest* `limit` events in the window, so a full page means the
        // older end was dropped — and the watermark would then advance past it for good. A deploy
        // storm is exactly when that happens and exactly when the alert matters.
        let paths = Paths()
        let (watcher, _, _) = makeWatcher(pageLimit: 2, route: { path in
            guard path.contains("/events") else { return (200, Fixtures.deploysPage([(id: "dep-1", status: "live")])) }
            paths.record(path)
            // Second page is short, which ends the walk.
            if path.contains("endTime=") {
                return (200, Fixtures.eventsPage([
                    (id: "evt-1", type: "image_pull_failed", timestamp: Self.eventTime),
                ]))
            }
            return (200, Fixtures.eventsPage([
                (id: "evt-3", type: "server_failed", timestamp: Self.laterEventTime),
                (id: "evt-2", type: "plan_changed", timestamp: Self.laterEventTime),
            ]))
        })

        let alerts = await watcher.poll()

        #expect(paths.all.count == 2)
        // The failure on the far side of the page boundary is the one this exists to catch.
        #expect(Set(alerts.map(\.id)) == ["evt-1", "evt-3"])
    }

    @Test("a short page ends the walk, so the ordinary case still costs one request")
    func shortPageDoesNotPage() async throws {
        let paths = Paths()
        let (watcher, _, _) = makeWatcher(pageLimit: 10, route: { path in
            if path.contains("/events") {
                paths.record(path)
                return (200, Fixtures.eventsPage([(id: "evt-1", type: "server_failed", timestamp: Self.eventTime)]))
            }
            return (200, Fixtures.deploysPage([(id: "dep-1", status: "live")]))
        })

        #expect(await watcher.poll().count == 1)
        #expect(paths.all.count == 1)
    }

    @Test("a page that repeats itself ends the walk instead of spinning")
    func allDuplicatePageStopsPaging() async throws {
        // Every event sharing one timestamp means `endTime` can't move, so the same page comes back
        // forever. Bounded by `maxPages` regardless, but this is the stop that should fire first.
        let paths = Paths()
        let (watcher, _, _) = makeWatcher(pageLimit: 2, maxPages: 5, route: { path in
            guard path.contains("/events") else { return (200, Fixtures.deploysPage([(id: "dep-1", status: "live")])) }
            paths.record(path)
            return (200, Fixtures.eventsPage([
                (id: "evt-2", type: "server_failed", timestamp: Self.eventTime),
                (id: "evt-1", type: "plan_changed", timestamp: Self.eventTime),
            ]))
        })

        #expect(await watcher.poll().count == 1)
        // One page to read it, one to discover it's the same page. Not five.
        #expect(paths.all.count == 2)
    }

    @Test("paging is bounded, so one busy service can't spend the whole background wake")
    func pagingIsBounded() async throws {
        let paths = Paths()
        // Never short, never repeating: the walk only stops because it's told to.
        let counter = Counter()
        let (watcher, _, _) = makeWatcher(pageLimit: 2, maxPages: 3, route: { path in
            guard path.contains("/events") else { return (200, Fixtures.deploysPage([(id: "dep-1", status: "live")])) }
            paths.record(path)
            let page = counter.next()
            return (200, Fixtures.eventsPage([
                (id: "evt-\(page)-b", type: "plan_changed", timestamp: Self.laterEventTime),
                (id: "evt-\(page)-a", type: "plan_changed", timestamp: Self.eventTime),
            ]))
        })

        _ = await watcher.poll()

        #expect(paths.all.count == 3)
    }

    // MARK: - The request itself

    @Test("the poll asks only for events since the watermark, unfiltered by type")
    func requestShape() async throws {
        let paths = Paths()
        let (watcher, _, _) = makeWatcher(route: { path in
            paths.record(path)
            return (200, "[]")
        })

        _ = await watcher.poll()

        let path = try #require(paths.all.first)
        #expect(path.contains("startTime="))
        // `type` takes a single event type, not a list, so filtering server-side would cost one
        // request per type per service. The filtering happens in the watcher instead.
        #expect(!path.contains("type="))
    }

    /// Collects the paths a routed transport was asked for. The route closure is `@Sendable`, so
    /// this can't just be a captured `var`.
    private final class Paths: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func record(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }
}
