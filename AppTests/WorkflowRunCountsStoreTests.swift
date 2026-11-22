import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
struct WorkflowRunCountsStoreTests {
    /// The shape Render returned for a sample workflow with `aggregateBy=state`: one series per
    /// outcome, labelled `taskState`, one point per UTC day.
    private static let byState = """
        [{"labels":[{"field":"taskState","value":"failed"},{"field":"resource","value":"wfl-1"}],"unit":"unitless",\
        "values":[{"timestamp":"2026-11-20T00:00:00Z","value":0},{"timestamp":"2026-11-21T00:00:00Z","value":2}]},\
        {"labels":[{"field":"resource","value":"wfl-1"},{"field":"taskState","value":"succeeded"}],"unit":"unitless",\
        "values":[{"timestamp":"2026-11-20T00:00:00Z","value":3},{"timestamp":"2026-11-21T00:00:00Z","value":4}]}]
        """

    /// 2026-11-22T17:11:57Z.
    private static let now = Date(timeIntervalSince1970: 1_795_367_517)

    private func store(answers: [(status: Int, body: String)]) -> (WorkflowRunCountsStore, StubTransport) {
        let transport = StubTransport(
            responses: answers.map { (status: $0.status, headers: [.contentType: "application/json"], body: $0.body) }
        )
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            retryPolicy: .none,
            transport: transport
        )
        let now = Self.now
        return (WorkflowRunCountsStore(client: client, workflowID: "wfl-1", clock: { now }), transport)
    }

    @Test("the window starts at UTC midnight, seven whole days including today")
    func windowStartsAtUTCMidnight() {
        let (start, end) = WorkflowRunCountsStore.window(endingAt: Self.now)
        #expect(start == ISO8601DateFormatter().date(from: "2026-11-16T00:00:00Z"))
        #expect(end == Self.now)
    }

    @Test("each outcome's days are summed, and only known outcomes are counted")
    func sumsByOutcome() async throws {
        let unknown = #"{"labels":[{"field":"taskState","value":"canceled"}],"unit":"unitless","values":[{"timestamp":"2026-11-21T00:00:00Z","value":5}]}"#
        let body = String(Self.byState.dropLast()) + "," + unknown + "]"
        let (store, transport) = store(answers: [(200, body)])

        await store.load()

        #expect(store.counts == .init(succeeded: 7, failed: 2))
        #expect(store.errorMessage == nil)
        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/metrics/task-runs-completed?"))
        #expect(path.contains("resource=wfl-1"))
        #expect(path.contains("resolutionSeconds=86400"))
        let items = URLComponents(string: path)?.queryItems ?? []
        let startTime = try #require(items.first { $0.name == "startTime" }?.value)
        // The generated client writes fractional seconds, which the default formatter won't parse.
        #expect(startTime.hasPrefix("2026-11-16T00:00:00"), "\(startTime)")
    }

    @Test("a failed refresh keeps the last counts and reports the error")
    func failedRefreshKeepsCounts() async {
        let (store, _) = store(answers: [(200, Self.byState), (500, #"{"message":"boom"}"#)])

        await store.load()
        await store.load()

        #expect(store.counts == .init(succeeded: 7, failed: 2))
        #expect(store.errorMessage != nil)
    }
}
