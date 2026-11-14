import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPITestSupport
import Testing

@testable import RenderAPI

@Suite("StatusMappingMiddleware")
struct StatusMappingMiddlewareTests {
    /// Runs one response through the middleware and returns whatever it produced or threw.
    private func map(
        status: Int,
        headers: HTTPFields = [:],
        body: String = "{}"
    ) async -> Result<HTTPResponse, RenderError> {
        let transport = StubTransport(responses: [(status, headers, body)])
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

    @Test("a generic 4xx carries Render's message as a sentence")
    func clientErrorCarriesMessage() async {
        // The live answer for starting a job on a Free-plan service.
        let result = await map(
            status: 400,
            body: #"{"id":"invalid-input","message":"free tier plans are not supported for jobs"}"#
        )
        #expect(result == .failure(.client(statusCode: 400, message: "Free tier plans are not supported for jobs.")))
    }

    @Test("401, 403 and 404 keep the app's own wording even when Render sends a message", arguments: [401, 403, 404])
    func namedStatusesIgnoreMessage(status: Int) async {
        let result = await map(status: status, body: #"{"message":"not found"}"#)
        #expect(result == .failure(RenderError.from(statusCode: status, message: nil)))
    }

    @Test("a 5xx never shows Render's text, which can be an internal error string")
    func serverErrorIgnoresMessage() async {
        let result = await map(status: 500, body: #"{"message":"pq: connection refused"}"#)
        #expect(result == .failure(.server(statusCode: 500, message: nil)))
    }

    @Test(
        "a body that isn't a usable message falls back to the generic text",
        arguments: ["", "not json", #"{"message":""}"#, #"{"message":42}"#, #"["message"]"#]
    )
    func unusableBodyFallsBack(body: String) async {
        let result = await map(status: 409, body: body)
        #expect(result == .failure(.client(statusCode: 409, message: nil)))
    }

    @Test("a message that already ends a sentence isn't given a second full stop")
    func keepsExistingPunctuation() async {
        let result = await map(status: 400, body: #"{"message":"Command is required."}"#)
        #expect(result == .failure(.client(statusCode: 400, message: "Command is required.")))
    }
}
