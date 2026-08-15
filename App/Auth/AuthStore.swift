import Foundation
import Observation
import RenderAPI

/// A Render account/team the credential can act as. Domain projection of `Components.Schemas.Owner`,
/// so views never touch generated types.
struct OwnerSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let email: String
    let isTeam: Bool
}

/// Owns authentication state for the whole app: the credential (in the Keychain, never here), the
/// list of owners it can act as, and which one is selected.
///
/// Two ways in, one at a time: the OAuth device flow ("Sign in with Render", the default) or a
/// pasted API key (the fallback). Signing in one way clears the other's credential. Either way,
/// validation is a `listOwners` call — a successful call proves the credential works *and* yields
/// the workspace list in one round trip. A pasted key is only written to the Keychain **after** it
/// validates, so a typo never displaces a working credential.
@MainActor
@Observable
final class AuthStore {
    enum Phase: Equatable {
        /// Launch-time silent revalidation of a stored credential — shows a splash, not onboarding.
        case restoring
        /// No usable credential: show onboarding.
        case needsKey
        /// Validating a pasted key or requesting a device grant: onboarding shows a busy state.
        case authenticating
        /// Device flow in progress: show the user code and wait for browser approval.
        case awaitingAuthorization(userCode: String, verificationURL: URL)
        /// Credential is good; show the service list.
        case authenticated
    }

    private(set) var phase: Phase = .restoring
    private(set) var owners: [OwnerSummary] = []
    private(set) var errorMessage: String?

    /// Persisted (non-secret) so the app reopens on the same workspace. Only credentials are secret.
    var selectedOwnerID: String? {
        didSet {
            UserDefaults.standard.set(selectedOwnerID, forKey: Self.selectedOwnerKey)
        }
    }

    private static let selectedOwnerKey = "selectedOwnerID"
    private let makeClient: @Sendable (any APIKeyProvider) -> RenderClient
    private let oauthClient: RenderOAuthClient
    private let apiKeyStore: any APIKeyStoring
    private let tokenStore: any OAuthTokenStoring
    /// The one provider instance every client shares — it holds refresh state (see its docs), so
    /// building a fresh one per call site would defeat the refresh coalescing.
    private let credentialProvider: OAuthCredentialProvider
    /// Internal (not private) so tests can await the poll's completion deterministically.
    private(set) var pollTask: Task<Void, Never>?

    /// - Parameters are injection seams for tests/previews; production defaults build the real thing.
    /// - Parameter shared: The process-wide credential provider. Production passes
    ///   ``SharedCredentials/shared`` so the background poll and this store refresh the *same*
    ///   token — see ``SharedCredentials``. `nil` (the default) builds a private provider from the
    ///   injected stores, which is what tests want.
    init(
        makeClient: @escaping @Sendable (any APIKeyProvider) -> RenderClient = { RenderClient(apiKeyProvider: $0) },
        oauthClient: RenderOAuthClient = OAuthEnvironment.makeClient(),
        apiKeyStore: any APIKeyStoring = KeychainAPIKeyStore(),
        tokenStore: any OAuthTokenStoring = KeychainOAuthTokenStore(),
        shared: SharedCredentials? = nil
    ) {
        self.makeClient = makeClient
        self.oauthClient = oauthClient
        self.apiKeyStore = apiKeyStore
        self.tokenStore = tokenStore
        // The provider's rejection callback fires from arbitrary request contexts, and `self`
        // isn't available yet while initializing the provider property — bridge through a relay
        // whose handler is attached right after init completes.
        let relay: RejectionRelay
        if let shared {
            relay = shared.rejectionRelay
            self.credentialProvider = shared.provider
        } else {
            relay = RejectionRelay()
            self.credentialProvider = OAuthCredentialProvider(
                oauthClient: oauthClient,
                tokenStore: tokenStore,
                legacyAPIKey: { (try? apiKeyStore.read()) ?? nil },
                onTerminalRejection: { relay.fire() }
            )
        }
        self.selectedOwnerID = UserDefaults.standard.string(forKey: Self.selectedOwnerKey)
        relay.handler = { [weak self] in
            Task { @MainActor in self?.handleSessionExpired() }
        }
    }

    /// A client bound to the shared credential provider, for feature stores to use once
    /// authenticated. Serves the pasted key or the OAuth access token, whichever is present.
    func authenticatedClient() -> RenderClient {
        makeClient(credentialProvider)
    }

    /// Called on launch: if a credential of either kind is stored, revalidate it silently;
    /// otherwise onboard. An expired-but-refreshable OAuth token refreshes inside the provider.
    func restore() async {
        let hasKey = ((try? apiKeyStore.read()) ?? nil) != nil
        let hasToken = ((try? tokenStore.read()) ?? nil) != nil
        guard hasKey || hasToken else {
            phase = .needsKey
            return
        }
        phase = .restoring
        await loadOwners(using: credentialProvider, persisting: nil)
    }

    // MARK: - OAuth device flow

    /// Starts the device-authorization flow: fetches a grant, surfaces the user code, and polls
    /// for the token in the background until the user approves in the browser.
    func beginDeviceAuthorization() async {
        phase = .authenticating
        errorMessage = nil
        do {
            let grant = try await oauthClient.createGrant()
            phase = .awaitingAuthorization(
                userCode: grant.userCode,
                verificationURL: grant.verificationURIComplete
            )
            pollTask?.cancel()
            pollTask = Task { await self.pollForApproval(grant: grant) }
        } catch {
            errorMessage = Self.describe(error)
            phase = .needsKey
        }
    }

    /// Abandons an in-progress device flow and returns to onboarding.
    func cancelDeviceAuthorization() {
        pollTask?.cancel()
        pollTask = nil
        phase = .needsKey
        errorMessage = nil
    }

    private func pollForApproval(grant: DeviceGrant) async {
        do {
            let token = try await oauthClient.pollForToken(grant: grant)
            guard !Task.isCancelled else { return }
            try? tokenStore.write(token)
            // One credential kind at a time: OAuth sign-in displaces any pasted key.
            try? apiKeyStore.write(nil)
            await loadOwners(using: credentialProvider, persisting: nil)
        } catch is CancellationError {
            // The user backed out; cancelDeviceAuthorization already reset the phase.
        } catch {
            errorMessage = Self.describe(error)
            phase = .needsKey
        }
    }

    /// The credential provider reports the refresh token was rejected outright (it has already
    /// cleared the stored pair): back to onboarding, with a reason.
    private func handleSessionExpired() {
        guard phase == .authenticated || phase == .restoring else { return }
        owners = []
        errorMessage = "Your session expired. Sign in again."
        phase = .needsKey
    }

    // MARK: - Pasted API key

    /// Validates an entered key and, on success, stores it and moves to the service list.
    func signIn(apiKey: String) async {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Enter your Render API key to continue."
            return
        }
        phase = .authenticating
        errorMessage = nil
        // Validate against a transient provider so a bad key is never written to the Keychain.
        await loadOwners(using: StaticAPIKeyProvider(trimmed), persisting: trimmed)
    }

    /// Clears the credential and returns to onboarding. An OAuth session is also revoked
    /// server-side, best-effort — sign-out must not block on (or fail with) the network.
    func signOut() {
        pollTask?.cancel()
        pollTask = nil
        if let accessToken = ((try? tokenStore.read()) ?? nil)?.accessToken {
            let oauthClient = oauthClient
            Task.detached { try? await oauthClient.revoke(accessToken: accessToken) }
        }
        try? apiKeyStore.write(nil)
        try? tokenStore.write(nil)
        owners = []
        selectedOwnerID = nil
        errorMessage = nil
        phase = .needsKey
    }

    private func loadOwners(using provider: any APIKeyProvider, persisting key: String?) async {
        let client = makeClient(provider)
        do {
            let owners = try await Self.fetchOwners(client)
            // Persist only after the key proves good — and displace any OAuth session, one
            // credential kind at a time.
            if let key {
                try? apiKeyStore.write(key)
                try? tokenStore.write(nil)
            }
            self.owners = owners
            if selectedOwnerID == nil || !owners.contains(where: { $0.id == selectedOwnerID }) {
                selectedOwnerID = owners.first?.id
            }
            phase = .authenticated
        } catch {
            let renderError = RenderError.wrapping(error)
            // A stored-but-now-invalid credential should drop us to onboarding, cleared.
            if renderError.requiresReauthentication {
                try? apiKeyStore.write(nil)
                try? tokenStore.write(nil)
            }
            errorMessage = renderError.errorDescription
            phase = .needsKey
        }
    }

    private static func fetchOwners(_ client: RenderClient) async throws -> [OwnerSummary] {
        let paginator = CursorPaginator(pageSize: 100) { cursor, limit in
            try await client.api
                .listOwners(query: .init(cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { (envelope: Components.Schemas.OwnerWithCursor) in
            (envelope, envelope.cursor ?? "")
        }
        let envelopes = try await paginator.collect()
        return envelopes.compactMap { envelope in
            guard let owner = envelope.owner else { return nil }
            return OwnerSummary(
                id: owner.id,
                name: owner.name,
                email: owner.email,
                isTeam: owner._type == .team
            )
        }
    }

    private static func describe(_ error: any Error) -> String {
        if let oauthError = error as? OAuthError {
            return oauthError.errorDescription ?? "Sign-in failed."
        }
        return RenderError.wrapping(error).errorDescription ?? "Sign-in failed."
    }
}
