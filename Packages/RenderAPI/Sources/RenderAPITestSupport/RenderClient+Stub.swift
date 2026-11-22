import Foundation
import HTTPTypes
import OpenAPIRuntime
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
        logReconnectPolicy: LogStream.ReconnectPolicy = .none,
        eventSourceConnector: any EventSourceConnecting = StubEventSourceConnector.refusing()
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
            logReconnectPolicy: logReconnectPolicy,
            eventSourceConnector: eventSourceConnector,
            // A stubbed failure should end the stream, not start a reconnect loop.
            eventReconnectPolicy: .none
        )
        return (client, transport)
    }

    /// A client whose responses are chosen by looking at the request, rather than by arrival order.
    ///
    /// Needed as soon as a store fires several requests *concurrently* — the metrics screen issues
    /// one per chart series — because then "the second body" is a race, not a fact. Routing on the
    /// path makes the same test deterministic however the task group happens to schedule.
    ///
    /// - Parameter route: Receives each request's path (query string included) and returns the JSON
    ///   body and status to answer with. Returning a non-2xx status is how a test makes one series
    ///   fail while the others succeed.
    public static func routed(
        logSocketConnector: any LogSocketConnecting = StubLogSocketConnector.refusing(),
        logReconnectPolicy: LogStream.ReconnectPolicy = .none,
        eventSourceConnector: any EventSourceConnecting = StubEventSourceConnector.refusing(),
        route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (client: RenderClient, transport: StubTransport) {
        let transport = StubTransport { request, _, _ in
            let answer = route(request.path ?? "")
            var response = HTTPResponse(status: .init(code: answer.status))
            response.headerFields = [.contentType: "application/json"]
            return (response, HTTPBody(answer.body))
        }
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            retryPolicy: .none,
            transport: transport,
            logSocketConnector: logSocketConnector,
            logReconnectPolicy: logReconnectPolicy,
            eventSourceConnector: eventSourceConnector,
            // A stubbed failure should end the stream, not start a reconnect loop.
            eventReconnectPolicy: .none
        )
        return (client, transport)
    }
}
