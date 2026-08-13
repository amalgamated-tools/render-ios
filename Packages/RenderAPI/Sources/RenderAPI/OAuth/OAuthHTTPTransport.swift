import Foundation

/// Raw HTTP seam for ``RenderOAuthClient``.
///
/// The OAuth endpoints aren't in Render's OpenAPI spec, so the generated `ClientTransport` (which
/// is keyed on operation IDs) doesn't fit — this mirrors how `LogStream` has its own
/// `LogSocketConnecting` seam for the one other thing the generator can't express.
public protocol OAuthHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Production transport. Each exchange gets its own 15-second deadline (matching the Go client's
/// `oauthRequestTimeout`) so a token refresh blocking an API request can't hang indefinitely.
public struct URLSessionOAuthTransport: OAuthHTTPTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.transport("Non-HTTP response from \(request.url?.host() ?? "unknown host")")
        }
        return (data, http)
    }
}
