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

    /// `servers` in the spec declares exactly one URL, so this is not configurable in practice —
    /// it stays a parameter only so tests can point at a stub.
    public static let productionBaseURL = URL(string: "https://api.render.com/v1")!

    public init(
        baseURL: URL = RenderClient.productionBaseURL,
        apiKeyProvider: any APIKeyProvider,
        retryPolicy: RetryMiddleware.Policy = .default,
        transport: any ClientTransport = URLSessionTransport()
    ) {
        self.api = Client(
            serverURL: baseURL,
            transport: transport,
            middlewares: [
                // Order matters: retry is outermost so a retried attempt re-reads the API key,
                // which matters if the user swapped workspaces mid-flight.
                RetryMiddleware(policy: retryPolicy),
                AuthMiddleware(provider: apiKeyProvider),
            ]
        )
    }
}
