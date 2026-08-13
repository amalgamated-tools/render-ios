import Foundation
import RenderAPITestSupport
import Testing

@testable import RenderAPI

@Suite("OAuthCredentialProvider")
struct OAuthCredentialProviderTests {
    private static let epoch = Date(timeIntervalSince1970: 1_000_000)
    private static let tokenJSON = """
        {"access_token":"acc-new","token_type":"bearer","expires_in":3600,"refresh_token":"ref-new"}
        """

    private func makeProvider(
        transport: StubOAuthTransport,
        store: InMemoryTokenStore,
        legacyAPIKey: @escaping @Sendable () -> String? = { nil },
        onTerminalRejection: @escaping @Sendable () -> Void = {}
    ) -> OAuthCredentialProvider {
        let client = RenderOAuthClient(
            clientID: "client-abc",
            transport: transport,
            sleep: { _ in },
            now: { Self.epoch }
        )
        return OAuthCredentialProvider(
            oauthClient: client,
            tokenStore: store,
            legacyAPIKey: legacyAPIKey,
            refreshLeeway: 120,
            now: { Self.epoch },
            onTerminalRejection: onTerminalRejection
        )
    }

    private func token(expiresIn: TimeInterval, refreshToken: String = "ref-old") -> OAuthToken {
        OAuthToken(
            accessToken: "acc-old",
            refreshToken: refreshToken,
            expiresAt: Self.epoch.addingTimeInterval(expiresIn)
        )
    }

    @Test("a fresh token is returned without touching the network")
    func freshTokenNoNetwork() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        let store = InMemoryTokenStore(token(expiresIn: 3600))
        let provider = makeProvider(transport: transport, store: store)

        #expect(await provider.apiKey() == "acc-old")
        #expect(transport.callCount == 0)
    }

    @Test("a token inside the leeway window refreshes, persists, and returns the new one")
    func nearExpiryRefreshes() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        let store = InMemoryTokenStore(token(expiresIn: 60))
        let provider = makeProvider(transport: transport, store: store)

        #expect(await provider.apiKey() == "acc-new")
        #expect(transport.callCount == 1)
        #expect(store.current?.accessToken == "acc-new")
        #expect(store.current?.refreshToken == "ref-new")
    }

    @Test("concurrent callers share a single refresh")
    func refreshesAreCoalesced() async throws {
        let transport = StubOAuthTransport { _, _ in
            // Yield so every caller reaches the provider before the first refresh completes.
            await Task.yield()
            let response = HTTPURLResponse(
                url: URL(string: "https://api.render.com/v1/token/refresh/")!,
                statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(Self.tokenJSON.utf8), response)
        }
        let store = InMemoryTokenStore(token(expiresIn: 60))
        let provider = makeProvider(transport: transport, store: store)

        let keys = await withTaskGroup(of: String?.self) { group in
            for _ in 0..<8 {
                group.addTask { await provider.apiKey() }
            }
            return await group.reduce(into: [String?]()) { $0.append($1) }
        }

        #expect(keys == Array(repeating: "acc-new", count: 8))
        #expect(transport.callCount == 1)
    }

    @Test("a rejected refresh token clears the store, fires the callback, and returns nil")
    func terminalRejection() async throws {
        let transport = StubOAuthTransport(responses: [(400, #"{"error":"invalid_grant"}"#)])
        let store = InMemoryTokenStore(token(expiresIn: 60))
        let rejected = Flag()
        let provider = makeProvider(transport: transport, store: store, onTerminalRejection: {
            rejected.set()
        })

        #expect(await provider.apiKey() == nil)
        #expect(store.current == nil)
        #expect(rejected.isSet)
    }

    @Test("a transient refresh failure serves the stale token and keeps the store intact")
    func transientFailureServesStale() async throws {
        let transport = StubOAuthTransport { _, _ in throw URLError(.notConnectedToInternet) }
        let store = InMemoryTokenStore(token(expiresIn: 60))
        let provider = makeProvider(transport: transport, store: store)

        #expect(await provider.apiKey() == "acc-old")
        #expect(store.current == token(expiresIn: 60))
    }

    @Test("a legacy pasted API key short-circuits all OAuth logic")
    func legacyKeyWins() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        // Even with an expired OAuth token present, the pasted key is what gets used.
        let store = InMemoryTokenStore(token(expiresIn: -10))
        let provider = makeProvider(transport: transport, store: store, legacyAPIKey: { "rnd_pasted" })

        #expect(await provider.apiKey() == "rnd_pasted")
        #expect(transport.callCount == 0)
    }

    @Test("no credential of either kind yields nil")
    func noCredential() async throws {
        let transport = StubOAuthTransport(responses: [(200, Self.tokenJSON)])
        let provider = makeProvider(transport: transport, store: InMemoryTokenStore(nil))

        #expect(await provider.apiKey() == nil)
        #expect(transport.callCount == 0)
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

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.withLock { value }
    }

    func set() {
        lock.withLock { value = true }
    }
}
