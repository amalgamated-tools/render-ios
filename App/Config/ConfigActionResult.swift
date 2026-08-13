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

    static func success(_ message: String) -> ConfigActionResult {
        ConfigActionResult(message: message, isFailure: false)
    }

    static func failure(_ error: any Error) -> ConfigActionResult {
        ConfigActionResult(
            message: RenderError.wrapping(error).errorDescription ?? "Something went wrong.",
            isFailure: true
        )
    }
}
