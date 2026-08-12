import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Turns a terminal error response into a thrown ``RenderError``.
///
/// Without this, every call site would have to switch over the generated `Output` enum's
/// per-status cases (`.unauthorized`, `.tooManyRequests`, …), which share no protocol across the
/// 207 operations — so the switch can't be written once. Mapping here instead means feature stores
/// use the generated throwing `.ok` accessor and funnel everything through
/// ``RenderError/wrapping(_:)``, and the app reasons about one error type.
///
/// It sits **outermost** in the stack (before ``RetryMiddleware``), so it only ever sees the
/// *final* response: a 429 or 5xx reaches it only after retries are exhausted, at which point
/// surfacing it is correct.
///
/// Only `>= 400` is mapped. 2xx/3xx pass through untouched so the generated client decodes the body
/// as usual, and a redirect is still handled by the transport.
public struct StatusMappingMiddleware: ClientMiddleware {
    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard response.status.code >= 400 else { return (response, responseBody) }

        switch response.status.code {
        case 429:
            // Informational for the UI message — retries are already exhausted by the time a 429
            // reaches this outermost layer. Numeric-seconds form only; clamped so a hostile value
            // can't drive a misleading "try again in 9999s".
            let retryAfter = response.headerFields[.retryAfter]
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                .map { min(max($0, 0), 60) }
            throw RenderError.rateLimited(retryAfter: retryAfter)
        default:
            throw RenderError.from(statusCode: response.status.code, message: nil)
        }
    }
}
