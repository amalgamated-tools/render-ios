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
        case 401, 403, 404:
            // These have their own wording, which says what to do next. Render's text for them
            // ("unauthorized", "not found") would replace it with less.
            throw RenderError.from(statusCode: response.status.code, message: nil)
        case 400...499:
            // The other 4xx are about this particular request, and Render's sentence is usually the
            // only useful thing to show: "free tier plans are not supported for jobs" says exactly
            // what "Request failed (400)" doesn't.
            let message = await Self.message(in: responseBody)
            throw RenderError.from(statusCode: response.status.code, message: message)
        default:
            throw RenderError.from(statusCode: response.status.code, message: nil)
        }
    }

    /// Render's error body is `{"id": …, "message": …}`. Returns the message as a sentence, or `nil`
    /// for anything else, including a body too long to be one.
    static func message(in body: HTTPBody?) async -> String? {
        guard let body,
              let data = try? await Data(collecting: body, upTo: 16 * 1024),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["message"] as? String
        else { return nil }

        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, message.count <= 300 else { return nil }
        let capitalised = message.prefix(1).uppercased() + message.dropFirst()
        return capitalised.last.map { ".!?".contains($0) } == true ? capitalised : capitalised + "."
    }
}
