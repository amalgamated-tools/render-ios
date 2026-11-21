import Foundation
import OpenAPIRuntime
import OpenAPIURLSession

/// Entry point to the Render public API.
///
/// Wraps the generated ``Client`` with the middleware stack and a fixed base URL, so feature code
/// never assembles a transport itself. The generated client is exposed as ``api`` rather than
/// hidden behind hand-written methods: with 207 operations, re-declaring each one would be pure
/// duplication. Feature stores call `client.api.someOperation(...)` and map the result into their
/// own domain types.
public struct RenderClient: Sendable {
    /// The generated client. Middleware is already attached.
    public let api: Client

    /// Live log tail. Separate from ``api`` because a `101` upgrade is the one thing the generator
    /// can't emit — see ``LogStream``. It shares this client's base URL and API key.
    public let logs: LogStream

    /// `servers` in the spec declares exactly one URL, so this is not configurable in practice —
    /// it stays a parameter only so tests can point at a stub.
    public static let productionBaseURL = URL(string: "https://api.render.com/v1")!

    // Kept so ``withRetryPolicy(_:)`` can rebuild the same stack with one thing changed.
    private let baseURL: URL
    private let apiKeyProvider: any APIKeyProvider
    private let transport: any ClientTransport
    private let logSocketConnector: any LogSocketConnecting
    private let logReconnectPolicy: LogStream.ReconnectPolicy

    /// The same client — same base URL, key, transport and middleware order — with a different
    /// retry policy. For endpoints where an automatic retry is wrong, such as Postgres query
    /// insights, whose one-request-a-minute allowance a retry would spend while the user waits.
    public func withRetryPolicy(_ policy: RetryMiddleware.Policy) -> RenderClient {
        RenderClient(
            baseURL: baseURL,
            apiKeyProvider: apiKeyProvider,
            retryPolicy: policy,
            transport: transport,
            logSocketConnector: logSocketConnector,
            logReconnectPolicy: logReconnectPolicy
        )
    }

    public init(
        baseURL: URL = RenderClient.productionBaseURL,
        apiKeyProvider: any APIKeyProvider,
        retryPolicy: RetryMiddleware.Policy = .default,
        transport: any ClientTransport = URLSessionTransport(),
        logSocketConnector: any LogSocketConnecting = URLSessionLogSocketConnector(),
        logReconnectPolicy: LogStream.ReconnectPolicy = .default
    ) {
        self.baseURL = baseURL
        self.apiKeyProvider = apiKeyProvider
        self.transport = transport
        self.logSocketConnector = logSocketConnector
        self.logReconnectPolicy = logReconnectPolicy
        self.logs = LogStream(
            baseURL: baseURL,
            apiKeyProvider: apiKeyProvider,
            connector: logSocketConnector,
            policy: logReconnectPolicy
        )
        self.api = Client(
            serverURL: baseURL,
            // Render sends microsecond-precision timestamps the default transcoder rejects.
            configuration: Configuration(dateTranscoder: RenderDateTranscoder()),
            transport: transport,
            middlewares: [
                // Order matters (first = outermost). StatusMapping is outermost so it sees only the
                // *final* response and maps a terminal 4xx/5xx to a thrown RenderError — after Retry
                // has done its retries. Retry sits above Auth so a retried attempt re-reads the API
                // key, which matters if the user swapped workspaces mid-flight.
                StatusMappingMiddleware(),
                // Only ever touches a 2xx body, so its place relative to the others doesn't matter;
                // here it sees the final response once, rather than once per retry.
                NullListMiddleware(),
                RetryMiddleware(policy: retryPolicy),
                AuthMiddleware(provider: apiKeyProvider),
            ]
        )
    }
}
