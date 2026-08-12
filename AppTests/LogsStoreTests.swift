import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("LogsStore")
struct LogsStoreTests {
    private func store(
        bodies: [String],
        status: Int = 200,
        connector: StubLogSocketConnector = .refusing(),
        maxLines: Int = 2000
    ) -> (LogsStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(
            jsonBodies: bodies,
            status: status,
            logSocketConnector: connector
        )
        let store = LogsStore(
            client: client,
            ownerID: Fixtures.ownerID,
            resourceIDs: ["srv-1"],
            pageSize: 2,
            maxLines: maxLines
        )
        return (store, transport)
    }

    // MARK: - History

    @Test("the first page loads newest-first and scopes the query to the resource")
    func loadsFirstPage() async throws {
        let (store, transport) = store(bodies: [
            Fixtures.logsPage(
                [(id: "log-2", message: "newer"), (id: "log-1", message: "older")],
                hasMore: false
            )
        ])

        await store.refresh()

        #expect(store.lines.map(\.id) == ["log-2", "log-1"])
        #expect(store.lines.first?.message == "newer")
        #expect(store.errorMessage == nil)
        #expect(store.hasMore == false)

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("ownerId=\(Fixtures.ownerID)"))
        #expect(path.contains("resource=srv-1"))
        #expect(path.contains("direction=backward"))
        // The first page asks for "now", so no window is pinned yet.
        #expect(!path.contains("startTime="))
    }

    @Test("the next page uses the window Render handed back, not one we computed")
    func pagesByServerWindow() async throws {
        let (store, transport) = store(bodies: [
            Fixtures.logsPage(
                [(id: "log-4", message: "d"), (id: "log-3", message: "c")],
                hasMore: true,
                nextStartTime: "2026-08-12T09:00:00Z",
                nextEndTime: "2026-08-12T09:30:00Z"
            ),
            Fixtures.logsPage([(id: "log-2", message: "b"), (id: "log-1", message: "a")], hasMore: false),
        ])

        await store.refresh()
        await store.loadNextPage()

        #expect(store.lines.map(\.id) == ["log-4", "log-3", "log-2", "log-1"])
        #expect(store.hasMore == false)
        let second = try #require(transport.requests.last?.path)
        // Percent-encoded colons, and re-encoded to millisecond precision by RenderDateTranscoder.
        // The point is that both edges came from the response rather than being recomputed here.
        #expect(second.contains("startTime=2026-08-12T09%3A00%3A00.000Z"))
        #expect(second.contains("endTime=2026-08-12T09%3A30%3A00.000Z"))
    }

    @Test("overlapping windows don't duplicate lines")
    func deduplicatesAcrossPages() async throws {
        // Windows are inclusive at the edges, so the boundary line comes back on both pages.
        let (store, _) = store(bodies: [
            Fixtures.logsPage([(id: "log-3", message: "c"), (id: "log-2", message: "b")], hasMore: true),
            Fixtures.logsPage([(id: "log-2", message: "b"), (id: "log-1", message: "a")], hasMore: false),
        ])

        await store.refresh()
        await store.loadNextPage()

        #expect(store.lines.map(\.id) == ["log-3", "log-2", "log-1"])
    }

    @Test("hasMore, not page length, decides whether paging continues")
    func trustsHasMoreOverPageLength() async throws {
        // A short page that still says hasMore — the cursor convention used elsewhere in the app
        // would stop here and silently hide the rest of the range.
        let (store, _) = store(bodies: [
            Fixtures.logsPage([(id: "log-2", message: "b")], hasMore: true),
            Fixtures.logsPage([(id: "log-1", message: "a")], hasMore: false),
        ])

        await store.refresh()
        #expect(store.hasMore)

        await store.loadNextPage()
        #expect(store.lines.map(\.id) == ["log-2", "log-1"])
        #expect(store.hasMore == false)
    }

    @Test("a failed page reports the error and stops paging until retried")
    func failureStopsPaging() async throws {
        let (store, transport) = store(bodies: [#"{"message":"nope"}"#], status: 500)

        await store.refresh()

        #expect(store.lines.isEmpty)
        #expect(store.errorMessage != nil)
        // Otherwise the list footer would re-fire loadNextPage on every redraw.
        #expect(store.hasMore == false)

        await store.loadNextPage()
        #expect(transport.callCount == 1)

        await store.retry()
        #expect(transport.callCount == 2)
    }

    @Test("filters are sent to Render, not applied on the device")
    func filtersGoToTheServer() async throws {
        let (store, transport) = store(bodies: [Fixtures.logsPage([], hasMore: false)])
        store.filter.levels = ["error", "warning"]
        store.filter.text = "timeout"

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("level=error"))
        #expect(path.contains("level=warning"))
        #expect(path.contains("text=timeout"))
    }

    // MARK: - Search

    @Test("search matches the message or any label value")
    func searchesMessagesAndLabels() async throws {
        let (store, _) = store(bodies: [
            Fixtures.logsPage(
                [
                    (id: "log-2", message: "everything is fine"),
                    (id: "log-1", message: "database timeout"),
                ],
                hasMore: false,
                instance: "srv-1-xyz"
            )
        ])

        await store.refresh()

        store.searchText = "timeout"
        #expect(store.visibleLines.map(\.id) == ["log-1"])

        // Labels are searchable so "the instance I just saw fail" is one paste away.
        store.searchText = "srv-1-xyz"
        #expect(store.visibleLines.count == 2)

        store.searchText = ""
        #expect(store.visibleLines.count == 2)
    }

    // MARK: - Live tail

    @Test("the live tail prepends new lines and reports its status")
    func liveTailPrepends() async throws {
        let connector = StubLogSocketConnector(frames: [
            .text(Fixtures.logFrame(id: "log-9", message: "live line")),
            .silence,
        ])
        let (store, _) = store(
            bodies: [Fixtures.logsPage([(id: "log-1", message: "history")], hasMore: false)],
            connector: connector
        )

        await store.refresh()
        store.startLiveTail()
        try await pollUntil { store.lines.count == 2 }

        // Prepended: the tail pushes in above the history, so the newest line stays at the top.
        #expect(store.lines.map(\.id) == ["log-9", "log-1"])
        #expect(store.liveStatus == .live)
        store.stopLiveTail()
    }

    @Test("replayed lines land in time order, not arrival order")
    func liveTailKeepsTimeOrder() async throws {
        // What `/logs/subscribe` actually does on connect: replays a burst of recent history, which
        // is not sorted relative to what the history pane already loaded. Found on the first live
        // pass, where a 3:50 build line got prepended above a 3:55 one.
        let connector = StubLogSocketConnector(frames: [
            .text(Fixtures.logFrame(id: "log-newer", message: "b", timestamp: "2026-08-12T09:35:00Z")),
            .text(Fixtures.logFrame(id: "log-oldest", message: "a", timestamp: "2026-08-12T09:20:00Z")),
            .silence,
        ])
        let (store, _) = store(
            bodies: [Fixtures.logsPage([(id: "log-middle", message: "m")], hasMore: false)],
            connector: connector
        )

        await store.refresh()
        store.startLiveTail()
        try await pollUntil { store.lines.count == 3 }

        #expect(store.lines.map(\.id) == ["log-newer", "log-middle", "log-oldest"])
        store.stopLiveTail()
    }

    @Test("pausing holds lines back, and resuming delivers them")
    func pauseBuffersLines() async throws {
        let connector = StubLogSocketConnector(frames: [
            .text(Fixtures.logFrame(id: "log-9", message: "arrived while paused")),
            .silence,
        ])
        let (store, _) = store(bodies: [Fixtures.logsPage([], hasMore: false)], connector: connector)

        await store.refresh()
        // Paused in the same turn the tail starts, before the first suspension point — otherwise the
        // race is the test's, not the store's, and the line lands before the pause does.
        store.startLiveTail()
        store.setPaused(true)
        try await pollUntil { store.pendingLines.count == 1 }

        // Held, not dropped: pausing to read something shouldn't cost you what arrives meanwhile.
        #expect(store.lines.isEmpty)
        #expect(store.pendingLines.map(\.id) == ["log-9"])

        store.setPaused(false)
        #expect(store.pendingLines.isEmpty)
        #expect(store.lines.map(\.id) == ["log-9"])
        store.stopLiveTail()
    }

    @Test("a stream that gives up surfaces the reason")
    func liveTailFailureIsReported() async throws {
        // Deliberately *not* a RenderError: the test bundle links RenderAPI twice (once as a package
        // framework, once statically), so an error thrown across that boundary fails its `as?` cast
        // and arrives as a generic transport failure. Asserting on a specific case here would be
        // asserting on the link layout. The package's own suite covers error mapping properly.
        struct HandshakeRefused: Error {}
        let connector = StubLogSocketConnector.refusing(HandshakeRefused())
        let (store, _) = store(bodies: [Fixtures.logsPage([], hasMore: false)], connector: connector)

        await store.refresh()
        store.startLiveTail()
        try await pollUntil { if case .failed = store.liveStatus { true } else { false } }

        guard case .failed(let message) = store.liveStatus else {
            Issue.record("expected the tail to report a failure, got \(store.liveStatus)")
            return
        }
        #expect(!message.isEmpty)
        // A tail that gave up isn't a tail: the screen offers to start a new one.
        #expect(connector.connectCount == 1)
    }

    @Test("stopping the tail keeps what it already delivered")
    func stopKeepsDeliveredLines() async throws {
        let connector = StubLogSocketConnector(frames: [
            .text(Fixtures.logFrame(id: "log-9", message: "live")),
            .silence,
        ])
        let (store, _) = store(bodies: [Fixtures.logsPage([], hasMore: false)], connector: connector)

        await store.refresh()
        store.startLiveTail()
        try await pollUntil { store.lines.count == 1 }
        store.stopLiveTail()

        #expect(store.isLive == false)
        #expect(store.lines.map(\.id) == ["log-9"])
    }

    @Test("a live line already in history isn't shown twice")
    func liveTailDeduplicatesAgainstHistory() async throws {
        let connector = StubLogSocketConnector(frames: [
            .text(Fixtures.logFrame(id: "log-1", message: "history")),
            .silence,
        ])
        let (store, _) = store(
            bodies: [Fixtures.logsPage([(id: "log-1", message: "history")], hasMore: false)],
            connector: connector
        )

        await store.refresh()
        store.startLiveTail()
        try await pollUntil { store.liveStatus == .live }
        // Nothing to wait *for* — give the socket its turn, then assert the absence.
        try await pollUntil(timeout: .milliseconds(200)) { store.lines.count > 1 }

        #expect(store.lines.map(\.id) == ["log-1"])
        store.stopLiveTail()
    }

    // MARK: - Buffer

    @Test("the buffer is bounded, and trimmed lines don't come back as new")
    func ringBufferIsBounded() async throws {
        // Re-sends the line the cap just pushed out.
        let connector = StubLogSocketConnector(frames: [
            .text(Fixtures.logFrame(id: "log-1", message: "oldest")),
            .silence,
        ])
        let (store, _) = store(
            bodies: [
                Fixtures.logsPage(
                    [(id: "log-3", message: "c"), (id: "log-2", message: "b")],
                    hasMore: true
                ),
                Fixtures.logsPage([(id: "log-1", message: "a")], hasMore: false),
            ],
            connector: connector,
            maxLines: 2
        )

        await store.refresh()
        await store.loadNextPage()

        // Newest kept, oldest dropped — a phone screen shows the recent end of the range.
        #expect(store.lines.map(\.id) == ["log-3", "log-2"])

        store.startLiveTail()
        try await pollUntil { store.liveStatus == .live }
        try await pollUntil(timeout: .milliseconds(200)) { store.lines.contains { $0.id == "log-1" } }

        // A trimmed line is still a line we've seen; re-admitting it would make the list churn.
        #expect(store.lines.map(\.id) == ["log-3", "log-2"])
        store.stopLiveTail()
    }

    /// Waits on state a detached socket reader has to produce. Polling rather than sleeping so the
    /// suite stays fast when things work and still fails rather than hangs when they don't.
    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
