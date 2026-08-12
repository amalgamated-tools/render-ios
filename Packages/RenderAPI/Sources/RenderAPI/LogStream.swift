import Foundation

/// One live log line, exactly as `GET /logs/subscribe` documents its frames.
///
/// This is the generated type for the `101` response body rather than a hand-written struct: the
/// spec does describe the frame, and reusing the generated shape means a change to it lands in the
/// same reviewable diff as every other spec change. Only the *transport* is hand-written.
public typealias LogEntryPayload = Operations.SubscribeLogs.Output.SwitchingProtocols.Body.JsonPayload

/// What a live tail reports to its consumer.
public enum LogStreamEvent: Sendable {
    /// The socket is open. Emitted on the first connect and again after every reconnect, so a UI can
    /// tell "still connected" from "back after a gap" — lines emitted during the gap are lost, and
    /// that is worth showing.
    case connected
    case entry(LogEntryPayload)
    /// The socket dropped and will be retried. `attempt` counts consecutive failures.
    case reconnecting(attempt: Int, delay: Duration)
}

/// A single WebSocket carrying log frames.
///
/// Abstracted so the reconnect logic can be tested without a network: the interesting behavior is
/// what happens when `receiveText()` throws, and a real socket can't be made to throw on cue.
public protocol LogSocket: Sendable {
    /// The next frame's text. Throws when the socket fails or the peer closes it.
    func receiveText() async throws -> String
    func close()
}

public protocol LogSocketConnecting: Sendable {
    func connect(to url: URL, headers: [String: String]) async throws -> any LogSocket
}

/// Live log tail over `GET /logs/subscribe`.
///
/// `swift-openapi-generator` can't express a `101` upgrade — it emits a `subscribeLogs` operation
/// whose success case is a body that never arrives, because the response *is* the protocol switch.
/// So this is the one hand-written transport in the app. It reuses everything it can: ``LogQuery``
/// builds the same parameters the generated operation would, ``LogEntryPayload`` is the generated
/// frame type, and failures come back as ``RenderError``.
///
/// Reconnection is transparent but **not** gap-free: Render replays nothing, so lines emitted while
/// the socket was down are gone. That's why ``LogStreamEvent/connected`` is re-emitted rather than
/// the reconnect being silent.
public struct LogStream: Sendable {
    /// How hard to try before giving up on a dropped socket.
    public struct ReconnectPolicy: Sendable, Hashable {
        public var initialDelay: Duration
        public var maxDelay: Duration
        /// Consecutive failures tolerated before the stream finishes with the last error. A
        /// successful connect resets the count, so a tail left open all day never exhausts it.
        public var maxAttempts: Int

        public init(initialDelay: Duration, maxDelay: Duration, maxAttempts: Int) {
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
            self.maxAttempts = maxAttempts
        }

        public static let `default` = ReconnectPolicy(
            initialDelay: .milliseconds(500),
            maxDelay: .seconds(30),
            maxAttempts: 6
        )

        /// Fail on the first drop. For tests, and for a "connect once" caller.
        public static let none = ReconnectPolicy(
            initialDelay: .zero,
            maxDelay: .zero,
            maxAttempts: 0
        )

        /// Exponential backoff, capped. No jitter: unlike the retry middleware this is one socket
        /// per user, not a thundering herd of requests.
        public func delay(forAttempt attempt: Int) -> Duration {
            let scale = 1 << min(attempt - 1, 16)
            let scaled = initialDelay * scale
            return scaled > maxDelay ? maxDelay : scaled
        }
    }

    private let baseURL: URL
    private let apiKeyProvider: any APIKeyProvider
    private let connector: any LogSocketConnecting
    private let policy: ReconnectPolicy

    public init(
        baseURL: URL = RenderClient.productionBaseURL,
        apiKeyProvider: any APIKeyProvider,
        connector: any LogSocketConnecting = URLSessionLogSocketConnector(),
        policy: ReconnectPolicy = .default
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.connector = connector
        self.policy = policy
    }

    /// Opens a tail and yields events until the consumer stops iterating, the stream is cancelled,
    /// or reconnection is exhausted.
    ///
    /// Cancelling the consuming task — or simply dropping the stream — closes the socket, via
    /// `onTermination`.
    public func subscribe(to query: LogQuery) -> AsyncThrowingStream<LogStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var attempt = 0
                while !Task.isCancelled {
                    do {
                        let socket = try await openSocket(query: query)
                        defer { socket.close() }
                        // Only a socket that actually opened clears the backoff, so a service that
                        // rejects the handshake every time still walks up to `maxAttempts`.
                        attempt = 0
                        continuation.yield(.connected)
                        try await read(from: socket, into: continuation)
                    } catch is CancellationError {
                        break
                    } catch {
                        let renderError = RenderError.wrapping(error)
                        attempt += 1
                        // A rejected key or a service the token can't see will be rejected again in
                        // 500ms, and again after that. Only retry what a retry could fix.
                        guard renderError.isRetryable, attempt <= policy.maxAttempts else {
                            continuation.finish(throwing: renderError)
                            return
                        }
                        let delay = policy.delay(forAttempt: attempt)
                        continuation.yield(.reconnecting(attempt: attempt, delay: delay))
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            break
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func openSocket(query: LogQuery) async throws -> any LogSocket {
        guard let key = await apiKeyProvider.apiKey(), !key.isEmpty else {
            // Same reasoning as AuthMiddleware: fail before the handshake rather than after a
            // round trip that can only come back 401.
            throw RenderError.unauthorized(message: "No API key is configured.")
        }
        return try await connector.connect(
            to: try Self.socketURL(baseURL: baseURL, query: query),
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"]
        )
    }

    /// Pumps frames until the socket fails, the peer closes it, or the task is cancelled — this
    /// never returns normally.
    private func read(
        from socket: any LogSocket,
        into continuation: AsyncThrowingStream<LogStreamEvent, any Error>.Continuation
    ) async throws {
        let decoder = Self.makeDecoder()
        while !Task.isCancelled {
            let text = try await socket.receiveText()
            guard let data = text.data(using: .utf8),
                  let entry = try? decoder.decode(LogEntryPayload.self, from: data)
            else {
                // Render sends occasional non-log frames, and one unrecognized frame is a bad reason
                // to tear down a tail someone is watching. Frames that never decode surface as a
                // stream that connects and stays empty, which the UI already distinguishes.
                continue
            }
            continuation.yield(.entry(entry))
        }
        try Task.checkCancellation()
    }

    /// `https://api.render.com/v1` → `wss://api.render.com/v1/logs/subscribe?…`.
    static func socketURL(baseURL: URL, query: LogQuery) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("logs/subscribe"),
            resolvingAgainstBaseURL: false
        ) else {
            throw RenderError.transport(description: "Couldn't build the log stream URL.")
        }
        // URLSession will upgrade an http(s) URL too, but the ws scheme is what the spec documents
        // and what a proxy in between expects to see.
        switch components.scheme {
        case "http": components.scheme = "ws"
        case "https", nil: components.scheme = "wss"
        default: break
        }
        components.queryItems = query.queryItems
        guard let url = components.url else {
            throw RenderError.transport(description: "Couldn't build the log stream URL.")
        }
        return url
    }

    /// Frames carry the same microsecond timestamps the REST API does, so they need the same
    /// leniency ``RenderDateTranscoder`` gives the generated client. Built per session rather than
    /// shared, because `JSONDecoder` is a mutable reference type.
    private static func makeDecoder() -> JSONDecoder {
        let transcoder = RenderDateTranscoder()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            return try transcoder.decode(string)
        }
        return decoder
    }
}

/// The production ``LogSocketConnecting``, over `URLSessionWebSocketTask`.
public struct URLSessionLogSocketConnector: LogSocketConnecting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(to url: URL, headers: [String: String]) async throws -> any LogSocket {
        var request = URLRequest(url: url)
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let task = session.webSocketTask(with: request)
        task.resume()
        // Nothing to await: URLSession reports a failed upgrade on the first receive(), which is
        // where URLSessionLogSocket turns it back into a RenderError.
        return URLSessionLogSocket(task: task)
    }
}

/// `@unchecked Sendable` because `URLSessionWebSocketTask` is a thread-safe Foundation class that
/// predates `Sendable` annotations; every member here is `let`.
private final class URLSessionLogSocket: LogSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func receiveText() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text):
                return text
            case .data(let data):
                return String(decoding: data, as: UTF8.self)
            @unknown default:
                throw RenderError.decoding(description: "Unknown WebSocket frame type.")
            }
        } catch {
            // A rejected handshake surfaces as an opaque URLError, but the HTTP response that caused
            // it is still hanging off the task — and the difference between "offline" and "your key
            // was rejected" decides whether reconnecting is worth attempting at all.
            if let response = task.response as? HTTPURLResponse, response.statusCode >= 400 {
                throw RenderError.from(statusCode: response.statusCode, message: nil)
            }
            throw RenderError.wrapping(error)
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
