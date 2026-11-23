import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport

/// Requests a stub transport saw, with their bodies as text.
final class SentRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(method: HTTPRequest.Method, path: String, body: String)] = []
    var all: [(method: HTTPRequest.Method, path: String, body: String)] { lock.withLock { requests } }
    func append(_ request: (HTTPRequest.Method, String, String)) { lock.withLock { requests.append(request) } }
}

/// Answers like `methodRouted`, and also records each request's method, path and body text.
func recordingClient(
    _ route: @escaping @Sendable (HTTPRequest.Method, String) -> (status: Int, body: String)
) -> (client: RenderClient, sent: SentRequests) {
    let sent = SentRequests()
    let transport = StubTransport { request, body, _ in
        let text = if let body { try await String(collecting: body, upTo: 1 << 20) } else { "" }
        sent.append((request.method, request.path ?? "", text))
        let answer = route(request.method, request.path ?? "")
        var response = HTTPResponse(status: .init(code: answer.status))
        response.headerFields = [.contentType: "application/json"]
        return (response, answer.body.isEmpty ? nil : HTTPBody(answer.body))
    }
    let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
    return (client, sent)
}
