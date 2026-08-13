import Foundation

/// Persistence seam for the legacy pasted API key — the read/write counterpart to
/// ``APIKeyProvider`` (which is read-only, per request). Exists so `AuthStore` can be unit-tested
/// with an in-memory store instead of the device Keychain, mirroring ``OAuthTokenStoring``.
public protocol APIKeyStoring: Sendable {
    func read() throws -> String?
    /// `nil`/empty deletes any stored key.
    func write(_ key: String?) throws
}

/// The production store, backed by the same Keychain item `KeychainAPIKeyProvider` reads.
public struct KeychainAPIKeyStore: APIKeyStoring {
    public init() {}

    public func read() throws -> String? {
        try Keychain.readAPIKey()
    }

    public func write(_ key: String?) throws {
        try Keychain.saveAPIKey(key)
    }
}
