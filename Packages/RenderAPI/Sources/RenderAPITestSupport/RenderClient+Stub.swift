import Foundation
import HTTPTypes
import RenderAPI

extension RenderClient {
    /// A client wired to a `StubTransport`, for tests that exercise a store end to end without a
    /// network.
    ///
    /// The transport comes back alongside the client so a test can assert on what was *sent* — the
    /// query a store builds is usually the thing worth checking.
    ///
    /// - Parameters:
    ///   - jsonBodies: One response body per request, in order. The last entry repeats once the
    ///     list is exhausted, so a single body answers every request.
    ///   - status: The status code every stubbed response carries.
    ///   - logSocketConnector: Answers `client.logs.subscribe(to:)`. Defaults to a connector that
    ///     refuses, so a test that doesn't care about live logs can't accidentally open a socket.
    public static func stubbed(
        jsonBodies: [String],
        status: Int = 200,
        logSocketConnector: any LogSocketConnecting = StubLogSocketConnector.refusing(),
        logReconnectPolicy: LogStream.ReconnectPolicy = .none
    ) -> (client: RenderClient, transport: StubTransport) {
        let transport = StubTransport(
            responses: jsonBodies.map { (status: status, headers: [.contentType: "application/json"], body: $0) }
        )
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            // Tests assert on the first request; retrying a stubbed failure would just make the
            // assertions count attempts.
            retryPolicy: .none,
            transport: transport,
            logSocketConnector: logSocketConnector,
            // Same reasoning as `retryPolicy: .none`: a stubbed drop should surface as a failure the
            // test can assert on, not as a reconnect loop it has to wait out.
            logReconnectPolicy: logReconnectPolicy
        )
        return (client, transport)
    }
}
