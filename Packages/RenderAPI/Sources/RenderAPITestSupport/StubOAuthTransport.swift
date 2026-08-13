import Foundation
import RenderAPI

/// An ``OAuthHTTPTransport`` that answers from a script instead of the network — the OAuth
/// counterpart to ``StubTransport``, and in this product for the same reason: both the package's
/// tests and the app target's tests need it.
public final class StubOAuthTransport: OAuthHTTPTransport, @unchecked Sendable {
    public typealias Handler = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)

    private let handler: Handler
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    /// Every request the transport was asked to send, in order.
    public var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    public var callCount: Int { requests.count }

    /// - Parameter handler: Receives the request and the 1-based call number.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Replays a fixed sequence of responses, one per call. Reuses the last entry once the
    /// sequence is exhausted, so "pending twice then approved forever" is one line.
    public convenience init(responses: [(status: Int, body: String)]) {
        self.init { request, call in
            let entry = responses[min(call - 1, responses.count - 1)]
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.render.com/v1")!,
                statusCode: entry.status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (Data(entry.body.utf8), response)
        }
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let call = lock.withLock {
            _requests.append(request)
            return _requests.count
        }
        return try await handler(request, call)
    }
}
