import Foundation
import RenderAPI

/// Hands out a scripted event stream per connect, so a reconnect can be scripted differently from
/// the first attempt, and records every request so a test can assert on the run IDs asked for.
public final class StubEventSourceConnector: EventSourceConnecting, @unchecked Sendable {
    public enum Step: Sendable {
        case line(String)
        /// Drops the connection.
        case failure(any Error)
        /// Stays open and silent until cancelled, like a stream waiting on a long run.
        case silence
    }

    public typealias Handler = @Sendable (_ attempt: Int) throws -> [Step]

    private let handler: Handler
    private let lock = NSLock()
    private var _requests: [URLRequest] = []

    /// Every request sent, in order.
    public var requests: [URLRequest] { lock.withLock { _requests } }
    public var connectCount: Int { requests.count }

    /// - Parameter handler: Receives the 1-based connect attempt and returns that connection's
    ///   script, or throws to fail the request itself. A script that runs out closes the stream.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Fails every connect, so a test that doesn't expect a stream can't open one by accident.
    public static func refusing(
        _ error: any Error = RenderError.transport(description: "No event stream in this test.")
    ) -> StubEventSourceConnector {
        StubEventSourceConnector { _ in throw error }
    }

    /// An SSE frame, as Render sends it, for one finished run.
    public static func completedFrame(id: String, status: String = "completed") -> [Step] {
        [
            .line("id: 0"),
            .line("event: task.completed"),
            .line(#"data: {"id":"\#(id)","status":"\#(status)","taskId":"tsk-1"}"#),
            .line(""),
        ]
    }

    public func lines(for request: URLRequest) async throws -> AsyncThrowingStream<String, any Error> {
        let attempt = lock.withLock {
            _requests.append(request)
            return _requests.count
        }
        let steps = try handler(attempt)
        return AsyncThrowingStream { continuation in
            let task = Task {
                for step in steps {
                    switch step {
                    case .line(let line):
                        continuation.yield(line)
                    case .failure(let error):
                        continuation.finish(throwing: error)
                        return
                    case .silence:
                        try? await Task.sleep(for: .seconds(3600))
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
