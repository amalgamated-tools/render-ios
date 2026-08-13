import Foundation
import RenderAPI

/// Configuration for Render's OAuth device-authorization endpoints.
enum OAuthEnvironment {
    /// PROTOTYPE ONLY: this is the Render CLI's client id (from the open-source CLI,
    /// pkg/client/oauth). Render issues one id per integration and there is no self-serve
    /// registration, so sessions started with this id appear as "Render CLI" in the dashboard and
    /// Render could rotate or re-scope it at any time. Replace with an id issued for this app
    /// before release.
    static let clientID = "429024F5E608930E2A65EF92591A25CC"

    /// The OAuth endpoints hang off the same host as the REST API.
    static func makeClient() -> RenderOAuthClient {
        RenderOAuthClient(baseURL: RenderClient.productionBaseURL, clientID: clientID)
    }
}
