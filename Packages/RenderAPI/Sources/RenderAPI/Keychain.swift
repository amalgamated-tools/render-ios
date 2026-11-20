import Foundation
import Security

/// A minimal wrapper over the Keychain for this app's secrets: the Render API key and, when the
/// user signs in with OAuth instead, the token pair issued by the device-authorization flow.
///
/// Uses generic-password items scoped by `service` + `account`. Items are
/// `kSecAttrAccessibleAfterFirstUnlock` so a background refresh after the first unlock can still
/// read them, but they never leave the device and are not included in unencrypted backups.
///
/// Secrets are the *only* thing that belongs here — everything non-secret (the selected owner id,
/// for instance) lives in `UserDefaults`.
public enum Keychain {
    /// Raised when the Keychain returns a status other than success or "item not found".
    public struct Error: Swift.Error, Sendable, Hashable {
        public let status: OSStatus
    }

    private static let service = "com.veverkap.RenderiOS.apiKey"
    private static let apiKeyAccount = "render-api-key"
    private static let oauthTokenAccount = "render-oauth-token"
    private static let orgAuditLogAccount = "render-org-audit-log"

    // MARK: - API key (legacy paste-a-key path)

    /// Stores `value`, replacing any existing key. Passing `nil`/empty deletes instead.
    public static func saveAPIKey(_ value: String?) throws {
        guard let value, !value.isEmpty else {
            try deleteAPIKey()
            return
        }
        try save(Data(value.utf8), account: apiKeyAccount)
    }

    /// Returns the stored key, or `nil` if none has been saved.
    public static func readAPIKey() throws -> String? {
        guard let data = try read(account: apiKeyAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the stored key. A missing item is not an error.
    public static func deleteAPIKey() throws {
        try delete(account: apiKeyAccount)
    }

    // MARK: - OAuth token pair

    /// Stores the token pair as one JSON blob, replacing any existing one. `nil` deletes instead.
    public static func saveOAuthToken(_ token: OAuthToken?) throws {
        guard let token else {
            try deleteOAuthToken()
            return
        }
        try save(try JSONEncoder().encode(token), account: oauthTokenAccount)
    }

    /// Returns the stored token pair, or `nil` if none has been saved.
    public static func readOAuthToken() throws -> OAuthToken? {
        guard let data = try read(account: oauthTokenAccount) else { return nil }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }

    /// Removes the stored token pair. A missing item is not an error.
    public static func deleteOAuthToken() throws {
        try delete(account: oauthTokenAccount)
    }

    // MARK: - Organization audit log credential

    /// Stores the organization ID and its Audit Log API key as one item, replacing any existing one.
    /// `nil` deletes instead. Kept apart from the sign-in credential, so signing out leaves it.
    public static func saveOrgAuditLogCredential(_ credential: OrgAuditLogCredential?) throws {
        guard let credential else {
            try delete(account: orgAuditLogAccount)
            return
        }
        try save(try JSONEncoder().encode(credential), account: orgAuditLogAccount)
    }

    /// Returns the stored credential, or `nil` if none has been saved.
    public static func readOrgAuditLogCredential() throws -> OrgAuditLogCredential? {
        guard let data = try read(account: orgAuditLogAccount) else { return nil }
        return try JSONDecoder().decode(OrgAuditLogCredential.self, from: data)
    }

    // MARK: - Generic-password plumbing

    private static func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func save(_ data: Data, account: String) throws {
        let query = query(for: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Error(status: addStatus) }
        default:
            throw Error(status: updateStatus)
        }
    }

    private static func read(account: String) throws -> Data? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Error(status: status)
        }
    }

    private static func delete(account: String) throws {
        let status = SecItemDelete(query(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error(status: status)
        }
    }
}
