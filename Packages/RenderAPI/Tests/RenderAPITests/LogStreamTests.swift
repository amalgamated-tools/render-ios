import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@Suite("LogStream")
struct LogStreamTests {
    private let query = LogQuery(ownerID: "tea-1", resourceIDs: ["srv-1"])

    private func makeStream(
        connector: StubLogSocketConnector,
        policy: LogStream.ReconnectPolicy = .none,
        apiKey: String? = "test-key"
    ) -> LogStream {
        LogStream(
            baseURL: URL(string: "https://api.render.com/v1")!,
            apiKeyProvider: StaticAPIKeyProvider(apiKey),
            connector: connector,
            policy: policy
        )
    }

    private func frame(id: String, message: String, timestamp: String = "2026-08-12T10:00:00.123456Z") -> String {
        """
        {"id":"\(id)","message":"\(message)","timestamp":"\(timestamp)",\
        "labels":[{"name":"level","value":"error"},{"name":"instance","value":"srv-1-abc"}]}
        """
    }

    /// Drains a stream, tolerating the terminal error that ends every finite stub.
    private func collect(_ stream: AsyncThrowingStream<LogStreamEvent, any Error>) async -> ([LogStreamEvent], (any Error)?) {
        var events: [LogStreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    @Test("frames decode into entries, with Render's microsecond timestamps")
    func decodesFrames() async throws {
        let connector = StubLogSocketConnector(frames: [
            .text(frame(id: "log-1", message: "boom")),
            .failure(RenderError.transport(description: "closed")),
        ])
        let (events, error) = await collect(makeStream(connector: connector).subscribe(to: query))

        #expect(events.count == 2)
        guard case .connected = events[0] else { Issue.record("expected .connected first"); return }
        guard case .entry(let entry) = events[1] else { Issue.record("expected an entry"); return }
        #expect(entry.id == "log-1")
        #expect(entry.message == "boom")
        // The default ISO8601 decoder rejects six fractional digits — this is the drift Phase 1 hit,
        // and the socket path has to handle it too since it doesn't go through the generated client.
        #expect(entry.timestamp == Date(timeIntervalSince1970: 1_786_528_800.123))
        #expect(entry.labels.first?.value == "error")
        #expect(error != nil)
    }

    @Test("a frame that isn't a log entry is skipped, not fatal")
    func skipsUndecodableFrames() async throws {
        let connector = StubLogSocketConnector(frames: [
            .text(#"{"hello":"world"}"#),
            .text("not json at all"),
            .text(frame(id: "log-1", message: "still here")),
            .failure(RenderError.transport(description: "closed")),
        ])
        let (events, _) = await collect(makeStream(connector: connector).subscribe(to: query))

        let entries = events.compactMap { event -> LogEntryPayload? in
            if case .entry(let entry) = event { return entry }
            return nil
        }
        #expect(entries.map(\.id) == ["log-1"])
    }

    @Test("a dropped socket reconnects and keeps reading")
    func reconnects() async throws {
        let connector = StubLogSocketConnector { attempt in
            attempt == 1
                ? [.text(frame(id: "log-1", message: "before")), .failure(RenderError.transport(description: "dropped"))]
                // A socket that opens resets the backoff — by design, so a tail left running all day
                // survives any number of drops. This one therefore has to end with something a retry
                // *can't* fix, or the test would reconnect forever.
                : [.text(frame(id: "log-2", message: "after")), .failure(RenderError.notFound(message: "gone"))]
        }
        let policy = LogStream.ReconnectPolicy(initialDelay: .zero, maxDelay: .zero, maxAttempts: 1)
        let (events, error) = await collect(makeStream(connector: connector, policy: policy).subscribe(to: query))

        let entries = events.compactMap { event -> String? in
            if case .entry(let entry) = event { return entry.id }
            return nil
        }
        #expect(entries == ["log-1", "log-2"])
        #expect(connector.connectCount == 2)
        // Re-announced on reconnect, because the gap in between lost lines.
        #expect(events.filter { if case .connected = $0 { true } else { false } }.count == 2)
        #expect(events.contains { if case .reconnecting(let attempt, _) = $0 { attempt == 1 } else { false } })
        // The second drop exhausts maxAttempts, so the stream reports it rather than finishing quietly.
        #expect(error != nil)
        // Both sockets are closed — a reconnect that leaked the old one would pile up file descriptors.
        #expect(connector.sockets.allSatisfy { $0.isClosed })
    }

    @Test("a rejected API key is not retried")
    func doesNotRetryUnauthorized() async throws {
        let connector = StubLogSocketConnector { _ in
            [.failure(RenderError.unauthorized(message: "nope"))]
        }
        let policy = LogStream.ReconnectPolicy(initialDelay: .zero, maxDelay: .zero, maxAttempts: 5)
        let (_, error) = await collect(makeStream(connector: connector, policy: policy).subscribe(to: query))

        // Reconnecting can't fix a bad key; it just burns five round trips before saying so.
        #expect(connector.connectCount == 1)
        #expect(RenderError.wrapping(try #require(error)) == .unauthorized(message: "nope"))
    }

    @Test("no API key fails before the handshake")
    func failsWithoutKey() async throws {
        let connector = StubLogSocketConnector(frames: [.text(frame(id: "log-1", message: "unreachable"))])
        let (_, error) = await collect(makeStream(connector: connector, apiKey: nil).subscribe(to: query))

        #expect(connector.connectCount == 0)
        #expect(RenderError.wrapping(try #require(error)).requiresReauthentication)
    }

    @Test("the socket carries the bearer token and the filter set")
    func sendsQueryAndAuth() async throws {
        let connector = StubLogSocketConnector(frames: [.failure(RenderError.transport(description: "closed"))])
        let filtered = LogQuery(
            ownerID: "tea-1",
            resourceIDs: ["srv-1", "srv-2"],
            text: ["timeout"],
            level: ["error", "warning"]
        )
        _ = await collect(makeStream(connector: connector).subscribe(to: filtered))

        let url = try #require(connector.urls.first)
        #expect(url.scheme == "wss")
        #expect(url.path == "/v1/logs/subscribe")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        // Repeated rather than comma-joined, matching the generated client's form/explode encoding.
        #expect(items.filter { $0.name == "resource" }.compactMap(\.value) == ["srv-1", "srv-2"])
        #expect(items.filter { $0.name == "level" }.compactMap(\.value) == ["error", "warning"])
        #expect(items.first { $0.name == "ownerId" }?.value == "tea-1")
        #expect(items.first { $0.name == "text" }?.value == "timeout")
        // Filters that weren't set are absent entirely, not sent empty.
        #expect(!items.contains { $0.name == "method" })
    }

    @Test("cancelling the consumer closes the socket")
    func cancellationClosesSocket() async throws {
        // Never yields and never fails: only cancellation can end this one.
        let connector = StubLogSocketConnector { _ in [] }
        let logStream = makeStream(connector: connector)

        // The AsyncThrowingStream is deliberately a temporary of the `for` statement rather than a
        // local: it owns the shared iteration context, so holding it in a variable would keep the
        // reader alive past the loop and defeat the thing being tested.
        for try await event in logStream.subscribe(to: query) {
            if case .connected = event { break }
        }

        // Breaking out of the loop terminates the stream, which cancels its reader and closes up.
        try await pollUntil { connector.sockets.first?.isClosed == true }
        #expect(connector.sockets.first?.isClosed == true)
    }

    @Test("backoff grows exponentially and stops at the cap")
    func backoffIsCapped() {
        let policy = LogStream.ReconnectPolicy(initialDelay: .milliseconds(500), maxDelay: .seconds(4), maxAttempts: 10)
        #expect(policy.delay(forAttempt: 1) == .milliseconds(500))
        #expect(policy.delay(forAttempt: 2) == .seconds(1))
        #expect(policy.delay(forAttempt: 3) == .seconds(2))
        #expect(policy.delay(forAttempt: 4) == .seconds(4))
        #expect(policy.delay(forAttempt: 9) == .seconds(4))
    }

    /// Waits for a condition the stream's own task has to run to satisfy. Polling rather than a
    /// fixed sleep so the test isn't slower — or flakier — than it needs to be.
    private func pollUntil(
        timeout: Duration = .seconds(2),
        _ condition: @Sendable () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

@Suite("LogQuery")
struct LogQueryTests {
    @Test("the generated list query carries only the filters that were set")
    func projectsOntoListLogs() {
        let query = LogQuery(
            ownerID: "tea-1",
            resourceIDs: ["srv-1"],
            text: ["boom"],
            level: ["error"],
            statusCode: ["500"]
        )
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 2000)

        let generated = query.listLogsQuery(startTime: start, endTime: end, limit: 50)

        #expect(generated.ownerId == "tea-1")
        #expect(generated.resource == ["srv-1"])
        #expect(generated.text == ["boom"])
        #expect(generated.level == ["error"])
        #expect(generated.statusCode == ["500"])
        #expect(generated.startTime == start)
        #expect(generated.endTime == end)
        #expect(generated.limit == 50)
        // Newest first, which is what a triage view wants and what the paging code assumes.
        #expect(generated.direction == .backward)
        // Empty means "no filter", which has to be nil — an empty array would serialize as nothing
        // useful and an explicit `method=` is not the same request.
        #expect(generated.method == nil)
        #expect(generated.host == nil)
        #expect(generated._type == nil)
        #expect(generated.path == nil)
    }
}
