import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Supplies the current Render API key at request time.
///
/// A closure rather than a stored `String` so that signing out, or switching keys, takes effect on
/// the next request without rebuilding the client.
public protocol APIKeyProvider: Sendable {
    func apiKey() async -> String?
}

/// Convenience provider for tests and previews.
public struct StaticAPIKeyProvider: APIKeyProvider {
    private let key: String?

    public init(_ key: String?) {
        self.key = key
    }

    public func apiKey() async -> String? { key }
}

/// Attaches `Authorization: Bearer <key>` to every outgoing request.
///
/// Render's spec declares a single global `BearerAuth` security scheme, so there is no per-operation
/// variation to model here.
public struct AuthMiddleware: ClientMiddleware {
    private let provider: any APIKeyProvider

    public init(provider: any APIKeyProvider) {
        self.provider = provider
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        guard let key = await provider.apiKey(), !key.isEmpty else {
            // Fail here rather than letting an unauthenticated request reach Render and come back
            // as a 401 — same user-visible outcome, but without the round trip or the log noise.
            throw RenderError.unauthorized(message: "No API key is configured.")
        }
        request.headerFields[.authorization] = "Bearer \(key)"
        request.headerFields[.accept] = "application/json"
        return try await next(request, body, baseURL)
    }
}
