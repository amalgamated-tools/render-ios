import Foundation
import RenderAPI

/// Which configuration screens a service type actually has.
///
/// The same job `MetricsCatalog` does for charts, and written down for the same reason: the claim
/// "a background worker has no custom domains" belongs somewhere a test can pin it, not spread across
/// `if` statements in a view.
///
/// **The bar for including something is higher here than it is for a chart.** A metrics chart offered
/// where Render collects nothing shows "No data in this range" — mild. These endpoints *fail* when they
/// don't apply to a service type, so a wrong guess is a red error banner on a screen the user opened on
/// purpose. Where it's unclear, the drill-down is therefore **withheld**, which is the opposite of the
/// Phase 4 default and deliberately so.
///
/// The live pass corrected one of these guesses and confirmed the reasoning behind the rule: asking a
/// *web service* for its routes or headers answers **400 — "invalid service type. Only static sites have
/// routes"**, not the `406` the spec advertises. So the gate is narrower than first written, and the
/// status code to expect is different too.
enum ServiceConfigCatalog {
    /// Custom domains: only the two types that serve public traffic.
    ///
    /// A private service is reachable only inside the private network, so a public hostname pointed at
    /// it would resolve to nothing; a worker and a cron job serve no HTTP at all.
    static func hasCustomDomains(_ type: Components.Schemas.ServiceType) -> Bool {
        type == .webService || type == .staticSite
    }

    /// Response header rules and redirect/rewrite rules: **static sites only.**
    ///
    /// This started as "static sites and web services", which read like the safe guess and was wrong.
    /// Render is unambiguous about it — `GET /services/{id}/routes` on a real web service answers
    /// `400 invalid service type. Only static sites have routes`, and the same for headers. Both
    /// features are properties of Render's static-site CDN, not of the HTTP path in front of a service.
    static func hasEdgeRules(_ type: Components.Schemas.ServiceType) -> Bool {
        type == .staticSite
    }

    /// Running instances and outbound IPs: everything **except static sites**.
    ///
    /// A static site is files on Render's CDN — no process of its own to list and no traffic leaving
    /// it. Withheld by the rule above; the outbound IPs endpoint declares `406` for exactly this kind
    /// of mismatch, and `loadFailureMessage` phrases it if the gate is ever wrong.
    static func hasInstancesAndOutboundIPs(_ type: Components.Schemas.ServiceType) -> Bool {
        type != .staticSite
    }

    /// What `406` means when one of these endpoints answers with it: not a fault, just a resource this
    /// service type doesn't have. Shown instead of the raw status in case a gate above is wrong.
    static let unsupportedMessage = "Not available for this service type."

    /// The message a domains/headers/routes screen shows for a failed load.
    ///
    /// The two status codes these endpoints declare and nothing else in the app does get plain sentences:
    /// `406` is the gates above being wrong, and `410` is a service that no longer exists — neither is
    /// something to retry, and "Request failed (406)" tells the reader nothing they can act on.
    static func loadFailureMessage(_ error: any Error) -> String {
        let renderError = RenderError.wrapping(error)
        if case .client(let statusCode, _) = renderError {
            switch statusCode {
            case 406: return unsupportedMessage
            case 410: return "This service no longer exists."
            default: break
            }
        }
        return renderError.errorDescription ?? "Something went wrong."
    }
}
