import Foundation

/// The production ``APIKeyProvider``: reads the Render API key from the ``Keychain`` on every
/// request.
///
/// Reading per-request (rather than caching a `String`) is what lets a sign-out or a key swap take
/// effect on the next call without rebuilding ``RenderClient`` — see the contract documented on
/// `APIKeyProvider` in `AuthMiddleware.swift`.
public struct KeychainAPIKeyProvider: APIKeyProvider {
    public init() {}

    public func apiKey() async -> String? {
        // A Keychain read failure is treated the same as "no key": the request then fails as
        // `.unauthorized` in AuthMiddleware, which routes the user back to onboarding — the correct
        // recovery either way.
        (try? Keychain.readAPIKey()) ?? nil
    }
}
