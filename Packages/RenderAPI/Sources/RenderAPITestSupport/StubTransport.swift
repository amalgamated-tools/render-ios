import Foundation
import HTTPTypes
import OpenAPIRuntime

/// A `ClientTransport` that answers from a script instead of the network.
///
/// Nothing in this repo's tests touches api.render.com — an API key is a user secret and CI must be
/// able to run offline.
///
/// This lives in a product rather than in a test target because two test suites need it: the
/// package's own tests and the app target's, which can't see another target's test sources.
public final class StubTransport: ClientTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest, HTTPBody?, Int) async throws -> (HTTPResponse, HTTPBody?)

    private let handler: Handler
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []

    /// Every request the transport was asked to send, in order.
    public var requests: [HTTPRequest] {
        lock.withLock { _requests }
    }

    public var callCount: Int { requests.count }

    /// - Parameter handler: Receives the request and the 1-based attempt number.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Replays a fixed sequence of responses, one per attempt. Reusing the last entry once the
    /// sequence is exhausted keeps "fails twice then succeeds forever" easy to express.
    public convenience init(responses: [(status: Int, headers: HTTPFields, body: String?)]) {
        self.init { _, _, attempt in
            let entry = responses[min(attempt - 1, responses.count - 1)]
            var response = HTTPResponse(status: .init(code: entry.status))
            response.headerFields = entry.headers
            return (response, entry.body.map { HTTPBody($0) })
        }
    }

    public func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let attempt = lock.withLock {
            _requests.append(request)
            return _requests.count
        }
        return try await handler(request, body, attempt)
    }
}
