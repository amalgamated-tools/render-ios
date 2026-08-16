import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("AuthStore")
struct AuthStoreTests {
    private static let grantJSON = """
        {"device_code":"dev-123","user_code":"WXYZ-9876",
         "verification_uri":"https://render.com/device",
         "verification_uri_complete":"https://render.com/device?code=WXYZ-9876",
         "expires_in":600,"interval":5}
        """
    private static let tokenJSON = """
        {"access_token":"acc-1","token_type":"bearer","expires_in":3600,"refresh_token":"ref-1"}
        """

    /// An AuthStore wired entirely to stubs: the REST client answers `listOwners`, the OAuth
    /// transport plays back the given script, and both credential stores are in memory.
    private func makeStore(
        oauthResponses: [(status: Int, body: String)],
        apiKey: String? = nil,
        oauthToken: OAuthToken? = nil,
        ownersBodies: [String] = [Fixtures.ownersPage([(id: Fixtures.ownerID, name: "Render-Prod")])],
        ownersStatus: Int = 200
    ) -> (store: AuthStore, oauthTransport: StubOAuthTransport, keys: InMemoryAPIKeyStore, tokens: InMemoryTokenStore) {
        let oauthTransport = StubOAuthTransport(responses: oauthResponses)
        let oauthClient = RenderOAuthClient(
            clientID: "client-abc",
            transport: oauthTransport,
            // Yield instead of waiting, so a pending-forever poll interleaves with the test body
            // (both run on the MainActor) instead of starving it.
            sleep: { _ in await Task.yield() }
        )
        let keys = InMemoryAPIKeyStore(apiKey)
        let tokens = InMemoryTokenStore(oauthToken)
        let store = AuthStore(
            makeClient: { _ in RenderClient.stubbed(jsonBodies: ownersBodies, status: ownersStatus).client },
            oauthClient: oauthClient,
            apiKeyStore: keys,
            tokenStore: tokens
        )
        return (store, oauthTransport, keys, tokens)
    }

    private func validToken() -> OAuthToken {
        OAuthToken(accessToken: "acc-0", refreshToken: "ref-0", expiresAt: Date().addingTimeInterval(3600))
    }

    // MARK: - Device flow

    @Test("beginDeviceAuthorization surfaces the user code and verification URL")
    func beginSurfacesCode() async throws {
        let (store, _, _, _) = makeStore(oauthResponses: [
            (200, Self.grantJSON),
            (400, #"{"error":"authorization_pending"}"#),
        ])

        await store.beginDeviceAuthorization()

        #expect(store.phase == .awaitingAuthorization(
            userCode: "WXYZ-9876",
            verificationURL: URL(string: "https://render.com/device?code=WXYZ-9876")!
        ))
        store.cancelDeviceAuthorization()
    }

    @Test("approval stores the token, clears any pasted key, and lands authenticated")
    func approvalAuthenticates() async throws {
        let (store, _, keys, tokens) = makeStore(
            oauthResponses: [
                (200, Self.grantJSON),
                (400, #"{"error":"authorization_pending"}"#),
                (200, Self.tokenJSON),
            ],
            apiKey: "rnd_old_pasted_key"
        )

        await store.beginDeviceAuthorization()
        await store.pollTask?.value

        #expect(store.phase == .authenticated)
        #expect(store.owners.map(\.id) == [Fixtures.ownerID])
        #expect(store.selectedOwnerID == Fixtures.ownerID)
        #expect(tokens.current?.accessToken == "acc-1")
        // One credential kind at a time: OAuth sign-in displaces the pasted key.
        #expect(keys.current == nil)
    }

    @Test("a grant that expires before approval returns to onboarding with a message")
    func expiryReturnsToOnboarding() async throws {
        let expiredGrant = Self.grantJSON.replacingOccurrences(of: "\"expires_in\":600", with: "\"expires_in\":0")
        let (store, _, _, tokens) = makeStore(oauthResponses: [
            (200, expiredGrant),
            (400, #"{"error":"authorization_pending"}"#),
        ])

        await store.beginDeviceAuthorization()
        await store.pollTask?.value

        #expect(store.phase == .needsKey)
        #expect(store.errorMessage?.contains("expired") == true)
        #expect(tokens.current == nil)
    }

    @Test("a failed grant request returns to onboarding instead of hanging")
    func grantFailureReturnsToOnboarding() async throws {
        let (store, _, _, _) = makeStore(oauthResponses: [(500, #"{"error":"boom"}"#)])

        await store.beginDeviceAuthorization()

        #expect(store.phase == .needsKey)
        #expect(store.errorMessage != nil)
    }

    @Test("cancelling the device flow stops the poll and returns to onboarding")
    func cancelStopsPolling() async throws {
        let (store, _, _, tokens) = makeStore(oauthResponses: [
            (200, Self.grantJSON),
            (400, #"{"error":"authorization_pending"}"#),
        ])

        await store.beginDeviceAuthorization()
        store.cancelDeviceAuthorization()
        await store.pollTask?.value

        #expect(store.phase == .needsKey)
        #expect(store.errorMessage == nil)
        #expect(tokens.current == nil)
    }

    // MARK: - Restore

    @Test("restore proceeds with a stored OAuth token and no pasted key")
    func restoreWithOAuthToken() async throws {
        let (store, _, _, _) = makeStore(oauthResponses: [], oauthToken: validToken())

        await store.restore()

        #expect(store.phase == .authenticated)
    }

    @Test("restore with no credential of either kind goes straight to onboarding")
    func restoreWithNothing() async throws {
        let (store, _, _, _) = makeStore(oauthResponses: [])

        await store.restore()

        #expect(store.phase == .needsKey)
    }

    @Test("a rejected credential during restore drops back to onboarding")
    func rejectedCredentialReturnsToOnboarding() async throws {
        // The clears-both-stores branch keys off `RenderError.requiresReauthentication`, which
        // can't be reached under the app test runner: the app binary and the test bundle each
        // statically link RenderAPI, so the 401 thrown on the test side fails the
        // `as? RenderError` cast on the app side and degrades to `.transport` (see the note in
        // the package manifest). The case mapping itself is covered by the package's
        // OwnersClientTests; here we pin the user-visible outcome.
        let (store, _, _, _) = makeStore(
            oauthResponses: [],
            apiKey: "rnd_stale",
            oauthToken: validToken(),
            ownersBodies: [#"{"id":"unauthorized","message":"nope"}"#],
            ownersStatus: 401
        )

        await store.restore()

        #expect(store.phase == .needsKey)
        #expect(store.errorMessage != nil)
    }

    // MARK: - Pasted key

    @Test("pasting a key still works and displaces any OAuth session")
    func pastedKeyDisplacesOAuth() async throws {
        let (store, _, keys, tokens) = makeStore(oauthResponses: [], oauthToken: validToken())

        await store.signIn(apiKey: "rnd_new_key")

        #expect(store.phase == .authenticated)
        #expect(keys.current == "rnd_new_key")
        #expect(tokens.current == nil)
    }

    // MARK: - Sign out

    @Test("signOut revokes the OAuth session best-effort and clears both stores")
    func signOutRevokes() async throws {
        let (store, oauthTransport, keys, tokens) = makeStore(
            oauthResponses: [(204, "")],
            oauthToken: validToken()
        )
        await store.restore()

        store.signOut()

        #expect(store.phase == .needsKey)
        #expect(keys.current == nil)
        #expect(tokens.current == nil)
        #expect(store.selectedOwnerID == nil)
        // The revoke is fired-and-forgotten on a detached task; give it a beat to land.
        for _ in 0..<100 where oauthTransport.callCount == 0 {
            await Task.yield()
        }
        let request = oauthTransport.requests.first
        #expect(request?.url?.path().contains("/oauth/revoke") == true)
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer acc-0")
    }

    // MARK: - Ending a session

    // Everything the device keeps that only makes sense inside a session — the failure watchlist and
    // its watermarks — is torn down through `onSessionEnded`. Both routes out have to call it: one
    // of them is a button, and the other one nobody taps.

    @Test("signing out ends the session for everything hanging off it")
    func signOutEndsSession() async throws {
        let ended = SessionEndTally()
        let oauthTransport = StubOAuthTransport(responses: [(204, "")])
        let store = AuthStore(
            makeClient: { _ in RenderClient.stubbed(jsonBodies: [Fixtures.ownersPage([(id: Fixtures.ownerID, name: "Render-Prod")])]).client },
            oauthClient: RenderOAuthClient(clientID: "client-abc", transport: oauthTransport, sleep: { _ in await Task.yield() }),
            apiKeyStore: InMemoryAPIKeyStore(nil),
            tokenStore: InMemoryTokenStore(validToken()),
            onSessionEnded: { ended.increment() }
        )
        await store.restore()

        store.signOut()

        #expect(ended.value == 1)
    }

    @Test("a rejected refresh token ends the session too, with nobody watching")
    func expiredSessionEndsSession() async throws {
        // The regression this pins: `onSessionEnded` used to live in the Sign Out button's closure,
        // so a session that ended because Render rejected the refresh token left the watchlist and
        // its watermarks behind — polling on a dead credential, and visible to whoever signed in
        // next on that device.
        //
        // Driven through the real `OAuthCredentialProvider` rather than by calling the handler:
        // an expired stored token forces a refresh, and `invalid_grant` is what makes it terminal.
        // That needs a client which actually consults the provider, so this one isn't `stubbed`.
        let ended = SessionEndTally()
        let oauthTransport = StubOAuthTransport(responses: [(400, #"{"error":"invalid_grant"}"#)])
        let expired = OAuthToken(
            accessToken: "acc-stale",
            refreshToken: "ref-revoked",
            expiresAt: Date().addingTimeInterval(-60)
        )
        let store = AuthStore(
            makeClient: { provider in
                RenderClient(
                    apiKeyProvider: provider,
                    transport: StubTransport(responses: [(status: 401, headers: [.contentType: "application/json"], body: #"{"id":"unauthorized","message":"nope"}"#)])
                )
            },
            oauthClient: RenderOAuthClient(clientID: "client-abc", transport: oauthTransport, sleep: { _ in await Task.yield() }),
            apiKeyStore: InMemoryAPIKeyStore(nil),
            tokenStore: InMemoryTokenStore(expired),
            onSessionEnded: { ended.increment() }
        )

        await store.restore()

        // The rejection hops back to the main actor on its own task; give it a bounded beat.
        for _ in 0..<100 where ended.value == 0 {
            await Task.yield()
        }
        #expect(ended.value == 1)
        #expect(store.phase == .needsKey)
    }
}

/// Counts calls from a `@Sendable` closure, which can't just bump a captured `var`. Named for what
/// it records rather than reusing `Counter` from `EnvVarsStoreTests`, which counts attempts.
private final class SessionEndTally: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class InMemoryAPIKeyStore: APIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    var current: String? {
        lock.withLock { key }
    }

    init(_ key: String?) {
        self.key = key
    }

    func read() throws -> String? {
        lock.withLock { key }
    }

    func write(_ key: String?) throws {
        lock.withLock { self.key = (key?.isEmpty == false) ? key : nil }
    }
}

private final class InMemoryTokenStore: OAuthTokenStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var token: OAuthToken?

    var current: OAuthToken? {
        lock.withLock { token }
    }

    init(_ token: OAuthToken?) {
        self.token = token
    }

    func read() throws -> OAuthToken? {
        lock.withLock { token }
    }

    func write(_ token: OAuthToken?) throws {
        lock.withLock { self.token = token }
    }
}
