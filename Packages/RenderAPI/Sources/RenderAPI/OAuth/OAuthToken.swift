import Foundation

/// An access/refresh token pair issued by Render's device-authorization or refresh-token exchange.
///
/// `expiresAt` is an absolute instant (computed as receipt time + the wire `expires_in`) rather
/// than a duration, so freshness checks don't depend on remembering when the token arrived.
public struct OAuthToken: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

/// Persistence seam for the OAuth token pair, so `OAuthCredentialProvider` and `AuthStore` can be
/// unit-tested with an in-memory store instead of the device Keychain.
public protocol OAuthTokenStoring: Sendable {
    func read() throws -> OAuthToken?
    /// `nil` deletes any stored token.
    func write(_ token: OAuthToken?) throws
}

/// The production store: one JSON blob in the Keychain, next to the legacy API-key item.
public struct KeychainOAuthTokenStore: OAuthTokenStoring {
    public init() {}

    public func read() throws -> OAuthToken? {
        try Keychain.readOAuthToken()
    }

    public func write(_ token: OAuthToken?) throws {
        try Keychain.saveOAuthToken(token)
    }
}
