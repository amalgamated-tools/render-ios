import Foundation
import RenderAPI

/// The outcome of a write, shown as a banner rather than an alert.
///
/// Config screens (env vars, secret files) all report the same way, so the type is shared rather
/// than re-declared per store. `ServiceDetailStore` keeps its own copy: its result is tied to a
/// `ServiceAction` and reloads different state.
struct ConfigActionResult: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let isFailure: Bool
    /// Whether the banner should offer to deploy.
    ///
    /// Set on a write that Render has saved but that isn't running yet — which is every successful
    /// config write, since the API applies the change without deploying. It's false once the deploy
    /// has been started, and false for failures: there is nothing to make live.
    let offersDeploy: Bool

    static func success(_ message: String, offersDeploy: Bool = false) -> ConfigActionResult {
        ConfigActionResult(message: message, isFailure: false, offersDeploy: offersDeploy)
    }

    static func failure(_ error: any Error) -> ConfigActionResult {
        ConfigActionResult(
            message: RenderError.wrapping(error).errorDescription ?? "Something went wrong.",
            isFailure: true,
            offersDeploy: false
        )
    }
}
