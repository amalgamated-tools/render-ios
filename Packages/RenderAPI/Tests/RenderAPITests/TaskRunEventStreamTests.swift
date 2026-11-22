import Foundation
@testable import RenderAPI
import RenderAPITestSupport
import Testing

@Suite("TaskRunEventStream")
struct TaskRunEventStreamTests {
    private let fastRetry = LogStream.ReconnectPolicy(initialDelay: .zero, maxDelay: .zero, maxAttempts: 3)

    private func makeStream(
        connector: StubEventSourceConnector,
        policy: LogStream.ReconnectPolicy = .none,
        apiKey: String? = "test-key"
    ) -> TaskRunEventStream {
        TaskRunEventStream(
            baseURL: URL(string: "https://api.render.com/v1")!,
            apiKeyProvider: StaticAPIKeyProvider(apiKey),
            connector: connector,
            policy: policy
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<TaskRunStreamEvent, any Error>
    ) async -> ([TaskRunStreamEvent], (any Error)?) {
        var events: [TaskRunStreamEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error)
        }
    }

    private func runIDs(in request: URLRequest) -> [String] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.filter { $0.name == "taskRunIds" }.compactMap(\.value) ?? []
    }

    // MARK: - Parser

    @Test func parserDispatchesOnBlankLineAndJoinsDataLines() {
        var parser = ServerSentEventParser()
        let lines = ["retry: 2000", "", ": comment", "id: 0", "event: task.completed", "data: {", "data: }", ""]
        let events = lines.compactMap { parser.consume($0) }
        #expect(events == [ServerSentEvent(type: "task.completed", data: "{\n}")])
    }

    @Test func parserDefaultsTypeAndFlushesUnterminatedEvent() {
        var parser = ServerSentEventParser()
        #expect(parser.consume("data:x") == nil)
        #expect(parser.finish() == ServerSentEvent(type: "message", data: "x"))
        #expect(parser.finish() == nil)
    }

    // MARK: - Stream

    @Test func requestAsksForEveryRunWithAuthAndEventStreamAccept() async {
        let connector = StubEventSourceConnector { _ in
            StubEventSourceConnector.completedFrame(id: "trn-a") + StubEventSourceConnector.completedFrame(id: "trn-b")
        }
        let (events, error) = await collect(makeStream(connector: connector).completions(of: ["trn-b", "trn-a"]))

        #expect(error == nil)
        #expect(events == [
            .connected,
            .completed(.init(id: "trn-a", status: "completed")),
            .completed(.init(id: "trn-b", status: "completed")),
        ])
        let request = try? #require(connector.requests.first)
        #expect(request?.url?.path == "/v1/task-runs/events")
        #expect(request.map(runIDs) == ["trn-a", "trn-b"])
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(request?.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        // Render sends nothing while a run is going, so the default 60 s timeout would drop it.
        #expect(request?.timeoutInterval == TaskRunEventStream.idleTimeout)
    }

    @Test func ignoresOtherEventsUnknownRunsAndRepeats() async {
        let connector = StubEventSourceConnector { _ in
            [.line("event: ping"), .line("data: {}"), .line("")]
                + StubEventSourceConnector.completedFrame(id: "trn-other")
                + [.line("event: task.completed"), .line("data: not json"), .line("")]
                + StubEventSourceConnector.completedFrame(id: "trn-a", status: "failed")
                + StubEventSourceConnector.completedFrame(id: "trn-a")
        }
        let (events, error) = await collect(makeStream(connector: connector).completions(of: ["trn-a"]))

        #expect(error == nil)
        #expect(events == [.connected, .completed(.init(id: "trn-a", status: "failed"))])
    }

    @Test func reconnectsWithOnlyTheRunsStillOutstanding() async {
        let connector = StubEventSourceConnector { attempt in
            attempt == 1
                ? StubEventSourceConnector.completedFrame(id: "trn-a") + [.failure(URLError(.networkConnectionLost))]
                : StubEventSourceConnector.completedFrame(id: "trn-b")
        }
        let (events, error) = await collect(
            makeStream(connector: connector, policy: fastRetry).completions(of: ["trn-a", "trn-b"])
        )

        #expect(error == nil)
        #expect(events == [
            .connected,
            .completed(.init(id: "trn-a", status: "completed")),
            .reconnecting(attempt: 1, delay: .zero),
            .connected,
            .completed(.init(id: "trn-b", status: "completed")),
        ])
        #expect(connector.requests.map(runIDs) == [["trn-a", "trn-b"], ["trn-b"]])
    }

    @Test func earlyCloseWithoutProgressGivesUpAfterMaxAttempts() async {
        // Accepts, then closes with nothing: the 30-minute idle close, or a misbehaving proxy. It must
        // not reconnect forever, so the consumer can fall back to polling.
        let connector = StubEventSourceConnector { _ in [.line("retry: 2000"), .line("")] }
        let (events, error) = await collect(makeStream(connector: connector, policy: fastRetry).completions(of: ["trn-a"]))

        #expect(connector.connectCount == 4)
        #expect(events.filter { $0 == .connected }.count == 4)
        #expect((error as? RenderError).map { if case .transport = $0 { true } else { false } } == true)
    }

    @Test func clientErrorIsNotRetried() async {
        let connector = StubEventSourceConnector { _ in
            throw RenderError.client(statusCode: 400, message: "invalid task run ID")
        }
        let (events, error) = await collect(makeStream(connector: connector, policy: fastRetry).completions(of: ["trn-x"]))

        #expect(events.isEmpty)
        #expect(connector.connectCount == 1)
        #expect((error as? RenderError) == .client(statusCode: 400, message: "invalid task run ID"))
    }

    @Test func missingKeyFailsWithoutConnecting() async {
        let connector = StubEventSourceConnector { _ in [] }
        let (_, error) = await collect(makeStream(connector: connector, apiKey: nil).completions(of: ["trn-a"]))

        #expect(connector.connectCount == 0)
        #expect((error as? RenderError)?.requiresReauthentication == true)
    }

    @Test func noRunsFinishesImmediately() async {
        let connector = StubEventSourceConnector { _ in [] }
        let (events, error) = await collect(makeStream(connector: connector).completions(of: []))

        #expect(events.isEmpty && error == nil)
        #expect(connector.connectCount == 0)
    }

    @Test func cancellingTheConsumerClosesASilentStream() async {
        let connector = StubEventSourceConnector { _ in [.silence] }
        let stream = makeStream(connector: connector).completions(of: ["trn-a"])
        let consumer = Task { await collect(stream) }
        while connector.connectCount == 0 { await Task.yield() }
        consumer.cancel()
        // Reaching here at all is the point: a silent stream would otherwise wait out its hour.
        // Whether `.connected` got out before the cancel is a race, and either is fine.
        let (events, _) = await consumer.value
        #expect(events.allSatisfy { $0 == .connected })
    }
}
