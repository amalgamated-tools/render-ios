import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// The cron-run half of the detail store: working out whether a run is in progress from the event
/// feed, and triggering and cancelling one.
@MainActor
@Suite("ServiceDetailStore cron runs")
struct ServiceDetailStoreTests {
    /// The cron job's events, changeable mid-test so a run can start and end between reloads.
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var _started = "[]"
        private var _ended = "[]"
        private var _now = ServiceDetailStoreTests.clock
        private var _eventsFail = false

        var started: String {
            get { lock.withLock { _started } }
            set { lock.withLock { _started = newValue } }
        }

        var ended: String {
            get { lock.withLock { _ended } }
            set { lock.withLock { _ended = newValue } }
        }

        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }

        /// When set, both event requests answer 500.
        var eventsFail: Bool {
            get { lock.withLock { _eventsFail } }
            set { lock.withLock { _eventsFail = newValue } }
        }
    }

    /// When the tests' events happen, and a clock a minute later.
    private nonisolated static let startedAt = "2026-11-14T05:26:40Z"
    private nonisolated static let clock = Date(timeIntervalSince1970: 1_794_634_060) // 05:27:40Z

    private nonisolated static func started(_ runID: String, at timestamp: String = startedAt) -> String {
        Fixtures.eventsPage(withDetails: [
            (id: "evt-s-\(runID)", type: "cron_job_run_started", timestamp: timestamp,
             details: #"{"cronJobRunId":"\#(runID)"}"#),
        ])
    }

    /// `cron_job_run_ended` events, newest first. Details as Render sent them in the live test.
    private nonisolated static func ended(_ runs: [(id: String, status: String, at: String)]) -> String {
        Fixtures.eventsPage(withDetails: runs.map { run in
            (id: "evt-e-\(run.id)", type: "cron_job_run_ended", timestamp: run.at,
             details: #"{"cronJobRunId":"\#(run.id)","status":"\#(run.status)","user":{"email":"a@b.c","id":"usr-1"}}"#)
        })
    }

    private func store(
        type: String = "cron_job",
        feed: Feed
    ) -> (ServiceDetailStore, StubTransport) {
        let service = Fixtures.serviceJSON(type: type, details: Fixtures.serviceDetailsJSON(for: type))
        let transport = StubTransport { request, _, _ in
            let path = request.path ?? ""
            let (status, body): (Int, String?) =
                if path.contains("/cron-jobs/") {
                    request.method == .delete
                        ? (204, nil)
                        : (200, #"{"id":"srv-1-new","status":"pending","triggeredBy":"a@b.c"}"#)
                } else if path.contains("/events"), feed.eventsFail {
                    (500, #"{"message":"boom"}"#)
                } else if path.contains("type=cron_job_run_started") {
                    (200, feed.started)
                } else if path.contains("type=cron_job_run_ended") {
                    (200, feed.ended)
                } else if path.contains("/deploys") {
                    (200, Fixtures.deploysPage([(id: "dep-1", status: "live")]))
                } else {
                    (200, service)
                }
            var response = HTTPResponse(status: .init(code: status))
            response.headerFields = [.contentType: "application/json"]
            return (response, body.map { HTTPBody($0) })
        }
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            retryPolicy: .none,
            transport: transport
        )
        // A long poll interval: these tests drive reloads themselves.
        let store = ServiceDetailStore(client: client, serviceID: "srv-1", pollInterval: .seconds(3600), now: { feed.now })
        return (store, transport)
    }

    @Test("a start with no matching end is a run in progress, and offers Cancel")
    func unmatchedStartIsActive() async {
        let feed = Feed()
        feed.started = Self.started("srv-1-2")
        feed.ended = Self.ended([(id: "srv-1-1", status: "successful", at: "2026-11-14T05:00:00Z")])
        let (store, _) = store(feed: feed)

        await store.load()
        defer { store.stopPolling() }

        #expect(store.activeCronRun?.id == "srv-1-2")
        #expect(store.activeCronRun?.startedAt == ISO8601DateFormatter().date(from: Self.startedAt))
        #expect(store.availableActions.contains(.cancelCronRun))
        #expect(store.lastCronRun?.statusTitle == "Succeeded")
    }

    @Test("a run with an end event isn't in progress, and its outcome is the last run")
    func matchedStartIsFinished() async {
        let feed = Feed()
        feed.started = Self.started("srv-1-2")
        feed.ended = Self.ended([(id: "srv-1-2", status: "canceled", at: "2026-11-14T05:27:01Z")])
        let (store, _) = store(feed: feed)

        await store.load()

        #expect(store.activeCronRun == nil)
        #expect(!store.availableActions.contains(.cancelCronRun))
        #expect(store.lastCronRun?.id == "srv-1-2")
        #expect(store.lastCronRun?.statusTitle == "Canceled")
    }

    @Test("an earlier run's end landing after the new run's start doesn't end the new run")
    func supersededRunEndingLate() async {
        let feed = Feed()
        feed.started = Self.started("srv-1-2")
        // Triggering cancels the run before; its end can be recorded after the new start.
        feed.ended = Self.ended([(id: "srv-1-1", status: "canceled", at: "2026-11-14T05:26:45Z")])
        let (store, _) = store(feed: feed)

        await store.load()
        defer { store.stopPolling() }

        #expect(store.activeCronRun?.id == "srv-1-2")
    }

    @Test("a start older than a day with no end is treated as a lost event")
    func staleStartIsIgnored() async {
        let feed = Feed()
        feed.started = Self.started("srv-1-old", at: "2026-11-12T05:00:00Z")
        let (store, _) = store(feed: feed)

        await store.load()

        #expect(store.activeCronRun == nil)
        #expect(!store.availableActions.contains(.cancelCronRun))
    }

    @Test("a triggered run shows as starting before Render records its start")
    func triggeredRunBeforeEvents() async {
        let feed = Feed()
        let (store, transport) = store(feed: feed)
        await store.load()

        await store.perform(.runCronJob)
        defer { store.stopPolling() }

        #expect(transport.requests.contains { $0.method == .post && ($0.path ?? "").hasSuffix("/cron-jobs/srv-1/runs") })
        #expect(store.activeCronRun == ActiveCronRun(id: "srv-1-new", startedAt: nil))
        #expect(store.availableActions.contains(.cancelCronRun))

        // Render catches up: the start arrives, then the end.
        feed.started = Self.started("srv-1-new")
        await store.refresh()
        #expect(store.activeCronRun?.startedAt != nil)

        feed.ended = Self.ended([(id: "srv-1-new", status: "successful", at: "2026-11-14T05:27:30Z")])
        await store.refresh()
        #expect(store.activeCronRun == nil)
        #expect(store.lastCronRun?.statusTitle == "Succeeded")
    }

    @Test("a triggered run whose events never arrive stops counting after the grace period")
    func triggeredRunExpires() async {
        let feed = Feed()
        let (store, _) = store(feed: feed)
        await store.load()
        await store.perform(.runCronJob)
        defer { store.stopPolling() }

        feed.now = Self.clock.addingTimeInterval(ServiceDetailStore.triggeredRunGrace - 1)
        await store.refresh()
        #expect(store.activeCronRun?.id == "srv-1-new")

        feed.now = Self.clock.addingTimeInterval(ServiceDetailStore.triggeredRunGrace + 1)
        await store.refresh()
        #expect(store.activeCronRun == nil)
    }

    @Test("a triggered run shows, and offers Cancel, even when its events can't be read")
    func triggeredRunWithEventsFailing() async {
        let feed = Feed()
        feed.ended = Self.ended([(id: "srv-1-1", status: "successful", at: "2026-11-14T05:00:00Z")])
        let (store, _) = store(feed: feed)
        await store.load()
        #expect(store.activeCronRun == nil)

        feed.eventsFail = true
        await store.perform(.runCronJob)
        defer { store.stopPolling() }

        #expect(store.activeCronRun == ActiveCronRun(id: "srv-1-new", startedAt: nil))
        #expect(store.availableActions.contains(.cancelCronRun))
        // The last run it did manage to read stays up.
        #expect(store.lastCronRun?.id == "srv-1-1")
    }

    @Test("triggering after cancelling an older run shows the new run, with Cancel")
    func triggerReplacesCancelingRun() async {
        let feed = Feed()
        feed.started = Self.started("srv-1-2")
        let (store, _) = store(feed: feed)
        await store.load()
        defer { store.stopPolling() }

        await store.perform(.cancelCronRun)
        #expect(store.isCancelingCronRun)

        // Render hasn't recorded the old run's end or the new run's start yet.
        await store.perform(.runCronJob)

        #expect(store.activeCronRun == ActiveCronRun(id: "srv-1-new", startedAt: nil))
        #expect(!store.isCancelingCronRun)
        #expect(store.availableActions.contains(.cancelCronRun))

        // The new run's start arrives: it's the run in progress from then on.
        feed.started = Self.started("srv-1-new", at: "2026-11-14T05:27:35Z")
        await store.refresh()
        #expect(store.activeCronRun?.id == "srv-1-new")
        #expect(store.activeCronRun?.startedAt != nil)
    }

    @Test("cancel sends DELETE, then shows canceling without a second Cancel until the run ends")
    func cancelWaitsForEndEvent() async {
        let feed = Feed()
        feed.started = Self.started("srv-1-2")
        let (store, transport) = store(feed: feed)
        await store.load()
        defer { store.stopPolling() }

        await store.perform(.cancelCronRun)

        #expect(transport.requests.contains { $0.method == .delete && ($0.path ?? "").hasSuffix("/cron-jobs/srv-1/runs") })
        #expect(store.actionResult?.message == "Cancel requested.")
        #expect(store.actionResult?.isFailure == false)
        // 204 came back but the end event hasn't yet: still running, as far as anyone knows.
        #expect(store.activeCronRun?.id == "srv-1-2")
        #expect(store.isCancelingCronRun)
        #expect(!store.availableActions.contains(.cancelCronRun))

        feed.ended = Self.ended([(id: "srv-1-2", status: "canceled", at: "2026-11-14T05:27:01Z")])
        await store.refresh()
        #expect(store.activeCronRun == nil)
        #expect(!store.isCancelingCronRun)
        #expect(store.lastCronRun?.statusTitle == "Canceled")
    }

    @Test("run starts are asked for over the last day, and run ends over all time")
    func startedEventsHaveADayWindow() async throws {
        let feed = Feed()
        let (store, transport) = store(feed: feed)

        await store.load()

        let paths = transport.requests.compactMap(\.path)
        let startedPath = try #require(paths.first { $0.contains("type=cron_job_run_started") })
        let endedPath = try #require(paths.first { $0.contains("type=cron_job_run_ended") })
        // A day before the test clock.
        #expect(startedPath.removingPercentEncoding?.contains("startTime=2026-11-13T05:27:40.000Z") == true)
        #expect(!endedPath.contains("startTime="))
    }

    @Test("a service that isn't a cron job never asks for run events")
    func nonCronSkipsEvents() async {
        let feed = Feed()
        let (store, transport) = store(type: "web_service", feed: feed)

        await store.load()

        #expect(!transport.requests.contains { ($0.path ?? "").contains("/events") })
        #expect(store.activeCronRun == nil && store.lastCronRun == nil)
    }
}
