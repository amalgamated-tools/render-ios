import Foundation

/// The ``APIKeyProvider`` for OAuth sign-in: returns a valid access token, refreshing it before it
/// expires. Because it conforms to the same protocol the pasted-key path uses, `AuthMiddleware`,
/// the generated client, and `LogStream` all work with it unchanged.
///
/// An actor, unlike the stateless `KeychainAPIKeyProvider`, because a refresh is shared state:
/// when several requests hit an expired token at once, exactly one refresh must run and everyone
/// must await it. Create **one** instance and reuse it for every client — a fresh instance per
/// call site would defeat the coalescing.
public actor OAuthCredentialProvider: APIKeyProvider {
    private let oauthClient: RenderOAuthClient
    private let tokenStore: any OAuthTokenStoring
    private let legacyAPIKey: @Sendable () -> String?
    private let refreshLeeway: TimeInterval
    private let now: @Sendable () -> Date
    private let onTerminalRejection: @Sendable () -> Void

    /// The single in-flight refresh, shared by every concurrent `apiKey()` caller.
    private var refreshTask: Task<OAuthToken, any Error>?

    /// - Parameters:
    ///   - refreshLeeway: Refresh this long *before* the token actually expires, so a token that's
    ///     valid now can't die between the check and the request landing at Render.
    ///   - onTerminalRejection: Called when Render rejects the refresh token outright — the stored
    ///     pair is already cleared; the app should route back to onboarding.
    public init(
        oauthClient: RenderOAuthClient,
        tokenStore: any OAuthTokenStoring = KeychainOAuthTokenStore(),
        legacyAPIKey: @escaping @Sendable () -> String? = { (try? Keychain.readAPIKey()) ?? nil },
        refreshLeeway: TimeInterval = 120,
        now: @escaping @Sendable () -> Date = Date.init,
        onTerminalRejection: @escaping @Sendable () -> Void = {}
    ) {
        self.oauthClient = oauthClient
        self.tokenStore = tokenStore
        self.legacyAPIKey = legacyAPIKey
        self.refreshLeeway = refreshLeeway
        self.now = now
        self.onTerminalRejection = onTerminalRejection
    }

    public func apiKey() async -> String? {
        // A pasted API key wins outright: the two credential kinds are mutually exclusive
        // (signing in one way clears the other), so a legacy key present means no OAuth state.
        if let key = legacyAPIKey(), !key.isEmpty {
            return key
        }

        guard let stored = try? tokenStore.read() else { return nil }
        if stored.expiresAt.timeIntervalSince(now()) > refreshLeeway {
            return stored.accessToken
        }

        do {
            return try await refreshCoalesced(stored).accessToken
        } catch let error as OAuthError where error == .refreshTokenRejected {
            // Render said this refresh token will never work again. Clear it and tell the app,
            // exactly once (coalescing means concurrent callers share this path).
            try? tokenStore.write(nil)
            onTerminalRejection()
            return nil
        } catch {
            // Transient (offline, 5xx, rate limit): serve the stale token rather than nil. The
            // request may come back 401, but a dead Wi-Fi moment must not wipe credentials or
            // block every request behind a failing refresh.
            return stored.accessToken
        }
    }

    private func refreshCoalesced(_ stored: OAuthToken) async throws -> OAuthToken {
        if let running = refreshTask {
            return try await running.value
        }
        let task = Task { [oauthClient, tokenStore] in
            let fresh = try await oauthClient.refresh(refreshToken: stored.refreshToken)
            try? tokenStore.write(fresh)
            return fresh
        }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }
}
