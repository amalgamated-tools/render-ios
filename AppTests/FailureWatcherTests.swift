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
            now: { Self.watchedAt }
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
