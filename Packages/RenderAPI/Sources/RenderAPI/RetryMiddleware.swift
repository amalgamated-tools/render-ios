import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Retries rate-limited, server-error, and transport-error requests with exponential backoff.
///
/// This app polls — service lists, deploy status, metrics — so 429 handling is load-bearing rather
/// than defensive. Render documents default rate-limit tiers and sends `Retry-After`; when it does,
/// that value wins over our own backoff curve.
public struct RetryMiddleware: ClientMiddleware {
    public struct Policy: Sendable {
        /// Total attempts including the first. `1` disables retrying.
        public var maxAttempts: Int
        /// Delay before the second attempt; doubles each subsequent attempt.
        public var baseDelay: TimeInterval
        /// Ceiling for a single backoff wait, before `Retry-After` is considered.
        public var maxDelay: TimeInterval
        /// Fraction of the computed delay applied as random jitter, to avoid a thundering herd
        /// when several screens refresh at once.
        public var jitterFraction: Double

        public init(
            maxAttempts: Int = 3,
            baseDelay: TimeInterval = 0.5,
            maxDelay: TimeInterval = 8,
            jitterFraction: Double = 0.25
        ) {
            self.maxAttempts = maxAttempts
            self.baseDelay = baseDelay
            self.maxDelay = maxDelay
            self.jitterFraction = jitterFraction
        }

        public static let `default` = Policy()
        public static let none = Policy(maxAttempts: 1)
    }

    private let policy: Policy
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// - Parameter sleep: Injectable so tests can assert on the backoff curve without waiting.
    public init(
        policy: Policy = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.policy = policy
        self.sleep = sleep
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        // A one-shot body can only be sent once, so a retry would transmit an empty request.
        // Better to make the single attempt and let the error surface honestly.
        let bodyIsReplayable = body == nil || body?.iterationBehavior == .multiple
        guard policy.maxAttempts > 1, bodyIsReplayable else {
            return try await next(request, body, baseURL)
        }

        var attempt = 1
        while true {
            let isLastAttempt = attempt >= policy.maxAttempts
            do {
                let (response, responseBody) = try await next(request, body, baseURL)
                guard
                    !isLastAttempt,
                    let delay = retryDelay(for: response, request: request, attempt: attempt)
                else {
                    return (response, responseBody)
                }
                // Drain the body we're discarding so the connection can be reused.
                if let responseBody { _ = try? await [UInt8](collecting: responseBody, upTo: .max) }
                try await sleep(delay)
            } catch {
                guard !isLastAttempt, shouldRetry(error), isIdempotent(request) else { throw error }
                try await sleep(backoff(forAttempt: attempt))
            }
            attempt += 1
        }
    }

    /// Returns the delay to wait before retrying, or `nil` if this response is final.
    private func retryDelay(
        for response: HTTPResponse,
        request: HTTPRequest,
        attempt: Int
    ) -> TimeInterval? {
        switch response.status.code {
        case 429:
            // A 429 means the request was rejected, not processed, so it is safe to repeat even
            // for POST/PATCH. Render's own `Retry-After` beats our guess when present.
            return retryAfter(in: response) ?? backoff(forAttempt: attempt)
        case 500...599:
            // Unlike 429, a 5xx may mean the request *was* processed. Only repeat it when
            // repeating is harmless.
            return isIdempotent(request) ? backoff(forAttempt: attempt) : nil
        default:
            return nil
        }
    }

    private func retryAfter(in response: HTTPResponse) -> TimeInterval? {
        guard let raw = response.headerFields[.retryAfter] else { return nil }
        if let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)) {
            return min(max(seconds, 0), 60)
        }
        // Retry-After may also be an HTTP-date.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(max(date.timeIntervalSinceNow, 0), 60)
    }

    private func backoff(forAttempt attempt: Int) -> TimeInterval {
        let exponential = policy.baseDelay * pow(2, Double(attempt - 1))
        let capped = min(exponential, policy.maxDelay)
        let jitter = capped * policy.jitterFraction
        return capped + Double.random(in: -jitter...jitter)
    }

    private func shouldRetry(_ error: any Error) -> Bool {
        // Never retry a cancelled task — the caller navigated away.
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        // `AuthMiddleware` throws before the request leaves the device when no key is configured.
        // Retrying that just burns the backoff budget on a guaranteed failure.
        // Anything unrecognised maps to `.transport`, which is retryable — the default stays
        // "retry", and only explicitly-terminal errors opt out.
        return RenderError.wrapping(error).isRetryable
    }

    /// Only repeat requests whose effect doesn't compound. Retrying `POST /deploys` after a 500
    /// could trigger a second deploy for a request that actually succeeded.
    private func isIdempotent(_ request: HTTPRequest) -> Bool {
        switch request.method {
        case .get, .head, .put, .delete, .options: true
        default: false
        }
    }
}
