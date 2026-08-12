import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import RenderAPI

@Suite("AuthMiddleware")
struct AuthMiddlewareTests {
    private func send(key: String?) async throws -> HTTPRequest {
        let transport = StubTransport(responses: [(200, [:], "{}")])
        let middleware = AuthMiddleware(provider: StaticAPIKeyProvider(key))
        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.render.com", path: "/v1/owners")

        _ = try await middleware.intercept(
            request,
            body: nil,
            baseURL: URL(string: "https://api.render.com/v1")!,
            operationID: "listOwners"
        ) { request, body, url in
            try await transport.send(request, body: body, baseURL: url, operationID: "listOwners")
        }

        return try #require(transport.requests.first)
    }

    @Test("the bearer token is attached")
    func attachesBearerToken() async throws {
        let sent = try await send(key: "rnd_abc123")
        #expect(sent.headerFields[.authorization] == "Bearer rnd_abc123")
        #expect(sent.headerFields[.accept] == "application/json")
    }

    /// Failing locally keeps a guaranteed-401 off the wire and out of Render's rate-limit budget.
    @Test("a missing key fails before the request is sent", arguments: [nil, ""] as [String?])
    func missingKeyFailsLocally(key: String?) async throws {
        await #expect(throws: RenderError.unauthorized(message: "No API key is configured.")) {
            _ = try await send(key: key)
        }
    }
}

@Suite("RenderError")
struct RenderErrorTests {
    @Test(
        "status codes map to cases",
        arguments: [
            (401, RenderError.unauthorized(message: nil)),
            (403, RenderError.forbidden(message: nil)),
            (404, RenderError.notFound(message: nil)),
            (429, RenderError.rateLimited(retryAfter: nil)),
            (422, RenderError.client(statusCode: 422, message: nil)),
            (500, RenderError.server(statusCode: 500, message: nil)),
            (503, RenderError.server(statusCode: 503, message: nil)),
        ]
    )
    func statusMapping(statusCode: Int, expected: RenderError) {
        #expect(RenderError.from(statusCode: statusCode, message: nil) == expected)
    }

    @Test("only 401 forces re-authentication")
    func reauthentication() {
        #expect(RenderError.unauthorized(message: nil).requiresReauthentication)
        #expect(!RenderError.forbidden(message: nil).requiresReauthentication)
        #expect(!RenderError.rateLimited(retryAfter: nil).requiresReauthentication)
    }

    @Test("retryability matches what RetryMiddleware acts on")
    func retryability() {
        #expect(RenderError.rateLimited(retryAfter: nil).isRetryable)
        #expect(RenderError.server(statusCode: 500, message: nil).isRetryable)
        #expect(RenderError.transport(description: "offline").isRetryable)
        #expect(!RenderError.unauthorized(message: nil).isRetryable)
        #expect(!RenderError.notFound(message: nil).isRetryable)
        #expect(!RenderError.decoding(description: "bad").isRetryable)
    }

    @Test("a decoding failure is distinguished from a transport failure")
    func decodingIsDistinct() {
        let decodingError = DecodingError.keyNotFound(
            Components.Schemas.Service.CodingKeys.id,
            .init(codingPath: [], debugDescription: "")
        )
        guard case .decoding = RenderError.wrapping(decodingError) else {
            Issue.record("expected .decoding")
            return
        }
    }

    @Test("an already-wrapped error passes through unchanged")
    func idempotentWrapping() {
        let original = RenderError.rateLimited(retryAfter: 5)
        #expect(RenderError.wrapping(original) == original)
    }
}
