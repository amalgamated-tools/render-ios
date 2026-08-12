import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPITestSupport
import Testing

@testable import RenderAPI

/// `RetryMiddleware` is exercised directly rather than through a generated operation, so these
/// tests stay valid when the spec changes. Sleeps are captured instead of performed.
@Suite("RetryMiddleware")
struct RetryMiddlewareTests {
    /// Runs one request through the middleware and reports what happened.
    private func run(
        method: HTTPRequest.Method = .get,
        body: HTTPBody? = nil,
        policy: RetryMiddleware.Policy = .init(maxAttempts: 3, baseDelay: 1, maxDelay: 8, jitterFraction: 0),
        responses: [(status: Int, headers: HTTPFields, body: String?)]
    ) async throws -> (status: Int, attempts: Int, sleeps: [TimeInterval]) {
        let recorder = SleepRecorder()
        let transport = StubTransport(responses: responses)
        let middleware = RetryMiddleware(policy: policy) { await recorder.record($0) }

        let request = HTTPRequest(method: method, scheme: "https", authority: "api.render.com", path: "/v1/services")
        let (response, _) = try await middleware.intercept(
            request,
            body: body,
            baseURL: URL(string: "https://api.render.com/v1")!,
            operationID: "test"
        ) { request, body, url in
            try await transport.send(request, body: body, baseURL: url, operationID: "test")
        }

        return (Int(response.status.code), transport.callCount, await recorder.sleeps)
    }

    @Test("a 200 is returned without retrying")
    func successIsNotRetried() async throws {
        let result = try await run(responses: [(200, [:], "{}")])
        #expect(result.status == 200)
        #expect(result.attempts == 1)
        #expect(result.sleeps.isEmpty)
    }

    @Test("a 429 is retried and Retry-After overrides the backoff curve")
    func retryAfterHeaderWins() async throws {
        let result = try await run(responses: [
            (429, [.retryAfter: "7"], nil),
            (200, [:], "{}"),
        ])
        #expect(result.status == 200)
        #expect(result.attempts == 2)
        // 7s from the header, not the 1s the policy's base delay would have produced.
        #expect(result.sleeps == [7])
    }

    @Test("a 429 without Retry-After falls back to exponential backoff")
    func backoffDoublesPerAttempt() async throws {
        let result = try await run(responses: [
            (429, [:], nil),
            (429, [:], nil),
            (200, [:], "{}"),
        ])
        // maxAttempts is 3, so the third response is the last one — it succeeds here.
        #expect(result.status == 200)
        #expect(result.attempts == 3)
        #expect(result.sleeps == [1, 2])
    }

    @Test("Retry-After is clamped so a hostile value can't hang the app")
    func retryAfterIsClamped() async throws {
        let result = try await run(responses: [
            (429, [.retryAfter: "99999"], nil),
            (200, [:], "{}"),
        ])
        #expect(result.sleeps == [60])
    }

    @Test("retrying stops at maxAttempts and returns the last response")
    func exhaustsAttempts() async throws {
        let result = try await run(responses: [(429, [:], nil)])
        #expect(result.status == 429)
        #expect(result.attempts == 3)
        #expect(result.sleeps.count == 2)
    }

    @Test("a 500 is retried for GET")
    func serverErrorRetriedForIdempotentMethod() async throws {
        let result = try await run(method: .get, responses: [
            (500, [:], nil),
            (200, [:], "{}"),
        ])
        #expect(result.status == 200)
        #expect(result.attempts == 2)
    }

    /// The important one: `POST /services/{id}/deploys` must not fire twice because the first
    /// attempt returned a 500 after Render had already accepted it.
    @Test("a 500 is NOT retried for POST")
    func serverErrorNotRetriedForPost() async throws {
        let result = try await run(method: .post, responses: [(500, [:], nil)])
        #expect(result.status == 500)
        #expect(result.attempts == 1)
        #expect(result.sleeps.isEmpty)
    }

    /// A 429 was never processed, so repeating it is safe regardless of method.
    @Test("a 429 IS retried for POST")
    func rateLimitRetriedForPost() async throws {
        let result = try await run(method: .post, responses: [
            (429, [.retryAfter: "2"], nil),
            (201, [:], "{}"),
        ])
        #expect(result.status == 201)
        #expect(result.attempts == 2)
    }

    @Test("a 404 is returned as-is")
    func clientErrorIsNotRetried() async throws {
        let result = try await run(responses: [(404, [:], nil)])
        #expect(result.status == 404)
        #expect(result.attempts == 1)
    }

    /// Retrying a one-shot body would resend an empty request, which is worse than not retrying.
    @Test("a single-iteration body disables retrying")
    func oneShotBodyIsNotRetried() async throws {
        let stream = AsyncStream<ArraySlice<UInt8>> { continuation in
            continuation.yield(ArraySlice(Array("{}".utf8)))
            continuation.finish()
        }
        let body = HTTPBody(stream, length: .unknown, iterationBehavior: .single)
        let result = try await run(method: .post, body: body, responses: [(429, [:], nil)])
        #expect(result.attempts == 1)
    }

    @Test("maxAttempts of 1 disables retrying")
    func policyNoneDisablesRetry() async throws {
        let result = try await run(policy: .none, responses: [(429, [:], nil)])
        #expect(result.attempts == 1)
    }
}

/// Captures requested sleep durations so the backoff curve can be asserted without real delays.
private actor SleepRecorder {
    var sleeps: [TimeInterval] = []

    func record(_ duration: TimeInterval) {
        sleeps.append(duration)
    }
}
