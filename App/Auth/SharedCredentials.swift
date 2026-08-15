import Foundation
import RenderAPI

/// The one OAuth credential provider in the process, and the clients built on it.
///
/// `OAuthCredentialProvider` coalesces concurrent refreshes **per instance**, so a second instance
/// is a second refresh — and Render's refresh endpoint hands back a new refresh token, so the loser
/// of that race would be left holding one that will never work again. Signing the user out of an
/// on-call app because a background poll and a foreground screen both noticed an expiring token is
/// not an acceptable failure.
///
/// One instance was enough while the only client was the one `AuthStore` builds for feature stores.
/// Background refresh adds a second entry point that runs with no screen on-screen — and, on a cold
/// background launch, with no `AuthStore` at all — so the provider has to outlive any view.
@MainActor
final class SharedCredentials {
    static let shared = SharedCredentials()

    let provider: OAuthCredentialProvider
    /// `AuthStore` attaches its handler here once it has finished initializing.
    let rejectionRelay: RejectionRelay

    private init() {
        let relay = RejectionRelay()
        rejectionRelay = relay
        provider = OAuthCredentialProvider(
            oauthClient: OAuthEnvironment.makeClient(),
            tokenStore: KeychainOAuthTokenStore(),
            legacyAPIKey: { (try? KeychainAPIKeyStore().read()) ?? nil },
            onTerminalRejection: { relay.fire() }
        )
    }

    /// A client bound to the shared provider. Cheap — the provider holds the state, not the client.
    func client() -> RenderClient {
        RenderClient(apiKeyProvider: provider)
    }

    /// Whether a credential of either kind is stored. The background poll's precondition, answered
    /// from the Keychain without a network round trip — both items are stored
    /// `kSecAttrAccessibleAfterFirstUnlock`, so this works while the device is locked.
    var hasStoredCredential: Bool {
        ((try? KeychainAPIKeyStore().read()) ?? nil) != nil
            || ((try? KeychainOAuthTokenStore().read()) ?? nil) != nil
    }
}

/// Bridges `OAuthCredentialProvider`'s `Sendable` rejection callback back to a store, which can't
/// capture `self` while its own initializer is still assigning the provider property.
final class RejectionRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable () -> Void)?

    var handler: (@Sendable () -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    func fire() {
        handler?()
    }
}
