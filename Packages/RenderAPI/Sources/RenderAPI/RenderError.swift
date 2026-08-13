import Foundation
import HTTPTypes
import OpenAPIRuntime

/// The single error type the app layer has to reason about.
///
/// Generated operations return an `Output` enum with a case per documented status code, which is
/// exhaustive but tedious at every call site. Feature code funnels those through
/// ``RenderError/from(statusCode:message:)`` so views can switch on intent ("re-auth", "back off",
/// "it's us, retry") rather than on numbers.
public enum RenderError: Error, Sendable, Hashable {
    /// 401 — the API key is missing, revoked, or malformed. The only recoverable action is to
    /// re-enter a key, so this is the one case that should clear the Keychain.
    case unauthorized(message: String?)
    /// 403 — the key is valid but lacks permission for this resource.
    case forbidden(message: String?)
    case notFound(message: String?)
    /// 429 — `retryAfter` is populated from the `Retry-After` header when the server sends one.
    case rateLimited(retryAfter: TimeInterval?)
    /// 4xx we don't model individually.
    case client(statusCode: Int, message: String?)
    /// 5xx. Retried automatically by ``RetryMiddleware`` before surfacing here.
    case server(statusCode: Int, message: String?)
    /// The request never produced a response — offline, DNS, TLS, cancellation.
    case transport(description: String)
    /// A response arrived but did not match the spec. Usually means upstream drift; worth
    /// surfacing distinctly so it isn't mistaken for a network problem.
    case decoding(description: String)

    public static func from(statusCode: Int, message: String?) -> RenderError {
        switch statusCode {
        case 401: .unauthorized(message: message)
        case 403: .forbidden(message: message)
        case 404: .notFound(message: message)
        case 429: .rateLimited(retryAfter: nil)
        case 400...499: .client(statusCode: statusCode, message: message)
        default: .server(statusCode: statusCode, message: message)
        }
    }

    /// Wraps anything thrown by a generated operation. `ClientError` is what
    /// swift-openapi-runtime throws for transport and coding failures; its `underlyingError`
    /// carries the real cause.
    public static func wrapping(_ error: any Error) -> RenderError {
        if let renderError = error as? RenderError { return renderError }
        if let clientError = error as? ClientError {
            let underlying = clientError.underlyingError
            if let renderError = underlying as? RenderError { return renderError }
            if underlying is DecodingError {
                return .decoding(description: clamped(String(describing: underlying)))
            }
            return .transport(description: clamped(underlying.localizedDescription))
        }
        if error is DecodingError {
            return .decoding(description: clamped(String(describing: error)))
        }
        return .transport(description: clamped(error.localizedDescription))
    }

    /// Long enough to name the problem, short enough that it stays a sentence.
    ///
    /// The runtime's "unexpected response" error stringifies the entire response — every header,
    /// the rate-limit counters, the CDN's ray ID. A live pass put all of it on a phone screen in
    /// red, wrapped over twenty lines, above a list. These messages are read by a person deciding
    /// what to do next, not pasted into a bug report.
    private static func clamped(_ description: String, limit: Int = 180) -> String {
        guard description.count > limit else { return description }
        return description.prefix(limit).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    /// True when retrying the *same* request could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .transport: true
        case .unauthorized, .forbidden, .notFound, .client, .decoding: false
        }
    }

    /// True when the stored API key should be discarded and the user sent back to onboarding.
    public var requiresReauthentication: Bool {
        if case .unauthorized = self { return true }
        return false
    }
}

extension RenderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized(let message):
            message ?? "Your API key was rejected. Enter a new one to continue."
        case .forbidden(let message):
            message ?? "This API key doesn't have access to that resource."
        case .notFound(let message):
            message ?? "Not found."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                "Rate limited by Render. Try again in \(Int(retryAfter.rounded(.up)))s."
            } else {
                "Rate limited by Render. Try again shortly."
            }
        case .client(let statusCode, let message):
            message ?? "Request failed (\(statusCode))."
        case .server(let statusCode, let message):
            message ?? "Render returned an error (\(statusCode))."
        case .transport(let description):
            "Couldn't reach Render: \(description)"
        case .decoding:
            "Render returned data this version of the app doesn't understand."
        }
    }
}
