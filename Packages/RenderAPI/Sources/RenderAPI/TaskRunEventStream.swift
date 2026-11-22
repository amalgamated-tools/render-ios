import Foundation

/// A task run reaching a terminal state, as `GET /task-runs/events` reports it.
///
/// Only the two fields the app acts on are decoded. The frame actually carries the whole run (the
/// same shape as `GET /task-runs/{id}`), but the spec's example shows a different, smaller shape,
/// so decoding only `id` and `status` keeps a spec/server disagreement from dropping events. A
/// consumer that wants the rest reloads the run, which it needs to do anyway for its children.
public struct TaskRunCompletion: Sendable, Hashable, Decodable {
    public let id: String
    /// `completed`, `failed` or `canceled` per the spec; kept raw so a new terminal state still
    /// arrives as an event rather than a decoding failure.
    public let status: String

    public init(id: String, status: String) {
        self.id = id
        self.status = status
    }
}

/// What a task-run event stream reports to its consumer.
public enum TaskRunStreamEvent: Sendable, Hashable {
    /// The stream is open. Emitted on the first connect and after every reconnect.
    case connected
    case completed(TaskRunCompletion)
    /// The stream dropped, or closed before every run finished, and will be reopened.
    case reconnecting(attempt: Int, delay: Duration)
}

/// One open `text/event-stream` response body, as lines.
///
/// Abstracted for the same reason as ``LogSocket``: the reconnect logic is the interesting part, and
/// a real connection can't be made to drop on cue.
public protocol EventSourceConnecting: Sendable {
    /// Sends `request` and returns its body split into lines, blank lines included, since a blank
    /// line is what ends an event. Throws a ``RenderError`` for a non-2xx response.
    func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, any Error>
}

/// Live completions over `GET /task-runs/events`.
///
/// The generator can model the operation, but only as a `String` body delivered once the response
/// ends, which for a stream that stays open until every run finishes means "never, then all at
/// once". So, like ``LogStream``, the transport is hand-written.
///
/// What Render does, checked against the live API:
/// - A run that already finished gets its event as soon as the stream opens. So a reconnect can't
///   miss a completion, and this resumes with exactly the runs still outstanding.
/// - The stream closes itself once every requested run has finished, and after 30 minutes with no
///   events. An early close is treated like a drop.
/// - An unknown run ID is a `400`, which isn't retried.
/// - Only terminal states are reported. Pending → Running still needs polling.
public struct TaskRunEventStream: Sendable {
    private let baseURL: URL
    private let apiKeyProvider: any APIKeyProvider
    private let connector: any EventSourceConnecting
    private let policy: LogStream.ReconnectPolicy

    /// Render closes an idle stream after 30 minutes and sends nothing in between, so the request
    /// timeout (which URLSession applies to the gap between bytes) has to outlast that. The default
    /// 60 seconds would drop every stream for a run longer than a minute.
    static let idleTimeout: TimeInterval = 31 * 60

    public init(
        baseURL: URL = RenderClient.productionBaseURL,
        apiKeyProvider: any APIKeyProvider,
        connector: any EventSourceConnecting = URLSessionEventSourceConnector(),
        policy: LogStream.ReconnectPolicy = .default
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.connector = connector
        self.policy = policy
    }

    /// Yields a completion for each of `runIDs` as it finishes, then ends. Each run is reported at
    /// most once. Cancelling the consumer closes the connection.
    ///
    /// The backoff only resets when a connection delivers a completion. A server that accepts and
    /// immediately closes, or a stream that idles out every 30 minutes, therefore still walks up to
    /// `maxAttempts` and ends with an error, so the consumer can fall back to polling.
    public func completions(of runIDs: [String]) -> AsyncThrowingStream<TaskRunStreamEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var remaining = Set(runIDs)
                var attempt = 0
                while !Task.isCancelled, !remaining.isEmpty {
                    do {
                        let lines = try await open(runIDs: remaining.sorted())
                        continuation.yield(.connected)
                        var parser = ServerSentEventParser()
                        var progressed = false
                        func handle(_ event: ServerSentEvent?) {
                            guard let event, event.type == "task.completed",
                                  let completion = try? JSONDecoder().decode(
                                      TaskRunCompletion.self, from: Data(event.data.utf8)
                                  ),
                                  remaining.remove(completion.id) != nil
                            else { return }
                            progressed = true
                            continuation.yield(.completed(completion))
                        }
                        for try await line in lines {
                            handle(parser.consume(line))
                            if remaining.isEmpty { break }
                        }
                        handle(parser.finish())
                        if progressed { attempt = 0 }
                        try Task.checkCancellation()
                        if remaining.isEmpty { break }
                        throw RenderError.transport(description: "The run event stream closed early.")
                    } catch is CancellationError {
                        break
                    } catch {
                        let renderError = RenderError.wrapping(error)
                        attempt += 1
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

    private func open(runIDs: [String]) async throws -> AsyncThrowingStream<String, any Error> {
        guard let key = await apiKeyProvider.apiKey(), !key.isEmpty else {
            throw RenderError.unauthorized(message: "No API key is configured.")
        }
        var request = URLRequest(url: try Self.url(baseURL: baseURL, runIDs: runIDs))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = Self.idleTimeout
        return try await connector.lines(for: request)
    }

    /// `…/task-runs/events?taskRunIds=a&taskRunIds=b`. Render takes the array as repeated keys.
    static func url(baseURL: URL, runIDs: [String]) throws -> URL {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("task-runs/events"),
            resolvingAgainstBaseURL: false
        ) else {
            throw RenderError.transport(description: "Couldn't build the run event stream URL.")
        }
        components.queryItems = runIDs.map { URLQueryItem(name: "taskRunIds", value: $0) }
        guard let url = components.url else {
            throw RenderError.transport(description: "Couldn't build the run event stream URL.")
        }
        return url
    }
}

/// One dispatched server-sent event.
struct ServerSentEvent: Sendable, Hashable {
    var type: String
    var data: String
}

/// The subset of the SSE line format Render uses: `event`, `data` (possibly several lines), comments
/// and blank-line dispatch. `id` and `retry` are read past; reconnection doesn't need them, because
/// Render replays finished runs on connect.
struct ServerSentEventParser {
    private var type = ""
    private var dataLines: [String] = []

    /// Feeds one line (without its terminator). Returns an event when the line ends one.
    mutating func consume(_ line: String) -> ServerSentEvent? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event": type = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    /// Dispatches an event left unterminated when the stream ended.
    mutating func finish() -> ServerSentEvent? { dispatch() }

    private mutating func dispatch() -> ServerSentEvent? {
        defer {
            type = ""
            dataLines = []
        }
        guard !dataLines.isEmpty else { return nil }
        return ServerSentEvent(type: type.isEmpty ? "message" : type, data: dataLines.joined(separator: "\n"))
    }
}

/// The production ``EventSourceConnecting``, over `URLSession.bytes(for:)`.
public struct URLSessionEventSourceConnector: EventSourceConnecting {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, any Error> {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw RenderError.wrapping(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RenderError.from(statusCode: http.statusCode, message: await Self.message(from: bytes))
        }
        // Not `bytes.lines`: it skips blank lines, and a blank line is what ends an SSE event.
        return AsyncThrowingStream { continuation in
            let task = Task {
                var buffer: [UInt8] = []
                do {
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error is CancellationError ? error : RenderError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Render's error bodies are `{"message": "…"}`. Read at most 64 KB of one.
    private static func message(from bytes: URLSession.AsyncBytes) async -> String? {
        var body: [UInt8] = []
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count >= 65_536 { break }
            }
        } catch {
            return nil
        }
        struct ErrorBody: Decodable { let message: String? }
        return (try? JSONDecoder().decode(ErrorBody.self, from: Data(body)))?.message
    }
}
