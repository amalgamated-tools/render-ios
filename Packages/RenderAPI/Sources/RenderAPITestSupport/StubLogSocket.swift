import Foundation
import RenderAPI

/// A ``LogSocket`` that replays a script of frames.
///
/// The interesting behavior of a log tail is what it does when a socket *ends* — so a script is a
/// list of outcomes, each either a frame to deliver or an error to throw, and the socket keeps
/// throwing the last error once the script runs out. That makes "two lines then a drop" and "drops
/// forever" both one-liners.
public final class StubLogSocket: LogSocket, @unchecked Sendable {
    public enum Frame: Sendable {
        case text(String)
        /// Ends this socket. The stream treats it like any other drop and may reconnect.
        case failure(any Error)
        /// A socket that stays open and says nothing. Ends only on cancellation — which is what a
        /// tail looks like between log lines, and the only way to script "connected, then quiet"
        /// without the repeating last frame turning into a hot loop.
        case silence
    }

    private let frames: [Frame]
    private let lock = NSLock()
    private var index = 0
    private var _isClosed = false

    public var isClosed: Bool { lock.withLock { _isClosed } }
    /// How many frames the consumer actually read — enough to tell "reconnected and read again"
    /// from "reconnected and stalled".
    public var readCount: Int { lock.withLock { index } }

    public init(frames: [Frame]) {
        self.frames = frames
    }

    public func receiveText() async throws -> String {
        let frame: Frame = lock.withLock {
            guard !frames.isEmpty else { return .silence }
            let frame = frames[min(index, frames.count - 1)]
            index += 1
            return frame
        }
        switch frame {
        case .text(let text):
            return text
        case .failure(let error):
            throw error
        case .silence:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    public func close() {
        lock.withLock { _isClosed = true }
    }
}

/// Hands out a fresh ``StubLogSocket`` per connect, so a reconnect can be scripted differently from
/// the first attempt — and so a test can assert on how many times the stream reconnected at all.
public final class StubLogSocketConnector: LogSocketConnecting, @unchecked Sendable {
    public typealias Handler = @Sendable (_ attempt: Int) throws -> [StubLogSocket.Frame]

    private let handler: Handler
    private let lock = NSLock()
    private var _sockets: [StubLogSocket] = []
    private var _urls: [URL] = []

    /// Every socket handed out, in connect order.
    public var sockets: [StubLogSocket] { lock.withLock { _sockets } }
    /// Every URL connected to, in order — this is where the query parameters get asserted.
    public var urls: [URL] { lock.withLock { _urls } }
    public var connectCount: Int { urls.count }

    /// - Parameter handler: Receives the 1-based connect attempt and returns that socket's script,
    ///   or throws to fail the handshake itself.
    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Every connect delivers the same frames.
    public convenience init(frames: [StubLogSocket.Frame]) {
        self.init { _ in frames }
    }

    /// Refuses every handshake with `error`. The default for stubbed clients: a test that opens a
    /// socket it didn't mean to should notice.
    public static func refusing(
        _ error: any Error = RenderError.transport(description: "No log socket was stubbed.")
    ) -> StubLogSocketConnector {
        StubLogSocketConnector { _ in throw error }
    }

    public func connect(to url: URL, headers: [String: String]) async throws -> any LogSocket {
        let attempt = lock.withLock {
            _urls.append(url)
            return _urls.count
        }
        let socket = StubLogSocket(frames: try handler(attempt))
        lock.withLock { _sockets.append(socket) }
        return socket
    }
}
