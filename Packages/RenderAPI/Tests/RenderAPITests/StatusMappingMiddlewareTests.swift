import Foundation
import HTTPTypes
import OpenAPIRuntime
import Testing

@testable import RenderAPI

@Suite("StatusMappingMiddleware")
struct StatusMappingMiddlewareTests {
    /// Runs one response through the middleware and returns whatever it produced or threw.
    private func map(
        status: Int,
        headers: HTTPFields = [:]
    ) async -> Result<HTTPResponse, RenderError> {
        let transport = StubTransport(responses: [(status, headers, "{}")])
        let middleware = StatusMappingMiddleware()
        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.render.com", path: "/v1/owners")
        do {
            let (response, _) = try await middleware.intercept(
                request,
                body: nil,
                baseURL: URL(string: "https://api.render.com/v1")!,
                operationID: "listOwners"
            ) { request, body, url in
                try await transport.send(request, body: body, baseURL: url, operationID: "listOwners")
            }
            return .success(response)
        } catch let error as RenderError {
            return .failure(error)
        } catch {
            return .failure(.transport(description: "unexpected: \(error)"))
        }
    }

    @Test("2xx passes through untouched", arguments: [200, 201, 204])
    func successPassesThrough(status: Int) async throws {
        let result = await map(status: status)
        guard case .success(let response) = result else {
            Issue.record("expected pass-through, got \(result)")
            return
        }
        #expect(response.status.code == status)
    }

    @Test(
        "terminal error statuses map to cases",
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
    func errorStatusesMap(status: Int, expected: RenderError) async throws {
        let result = await map(status: status)
        #expect(result == .failure(expected))
    }

    @Test("429 carries a clamped Retry-After for the UI message")
    func rateLimitedCarriesRetryAfter() async throws {
        let result = await map(status: 429, headers: [.retryAfter: "12"])
        #expect(result == .failure(.rateLimited(retryAfter: 12)))

        // A hostile value can't drive a misleading countdown.
        let hostile = await map(status: 429, headers: [.retryAfter: "99999"])
        #expect(hostile == .failure(.rateLimited(retryAfter: 60)))
    }
}
