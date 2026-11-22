import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport

/// Like `RenderClient.routed`, but the route also sees the method, since fetching and cancelling a
/// run share a path. The run event stream refuses by default, so a store that opens one falls back to
/// polling instead of reaching the network.
func methodRouted(
    eventSourceConnector: any EventSourceConnecting = StubEventSourceConnector.refusing(),
    _ route: @escaping @Sendable (HTTPRequest.Method, String) -> (status: Int, body: String)
) -> (client: RenderClient, transport: StubTransport) {
    let transport = StubTransport { request, _, _ in
        let answer = route(request.method, request.path ?? "")
        var response = HTTPResponse(status: .init(code: answer.status))
        response.headerFields = [.contentType: "application/json"]
        return (response, answer.body.isEmpty ? nil : HTTPBody(answer.body))
    }
    let client = RenderClient(
        apiKeyProvider: StaticAPIKeyProvider("test-key"),
        retryPolicy: .none,
        transport: transport,
        eventSourceConnector: eventSourceConnector,
        eventReconnectPolicy: .none
    )
    return (client, transport)
}

final class FetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    /// Returns the count before this call.
    func next() -> Int { lock.withLock { defer { value += 1 }; return value } }
}
