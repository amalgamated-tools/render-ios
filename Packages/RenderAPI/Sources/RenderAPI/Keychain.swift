import Foundation
import Security

/// A minimal wrapper over the Keychain for a single kind of secret: the Render API key.
///
/// Uses a generic-password item scoped by `service` + `account`. Items are
/// `kSecAttrAccessibleAfterFirstUnlock` so a background refresh after the first unlock can still
/// read the key, but the key never leaves the device and is not included in unencrypted backups.
///
/// The API key is the *only* thing that belongs here — everything non-secret (the selected owner
/// id, for instance) lives in `UserDefaults`.
public enum Keychain {
    /// Raised when the Keychain returns a status other than success or "item not found".
    public struct Error: Swift.Error, Sendable, Hashable {
        public let status: OSStatus
    }

    private static let service = "com.veverkap.RenderiOS.apiKey"
    private static let account = "render-api-key"

    /// Stores `value`, replacing any existing key. Passing `nil`/empty deletes instead.
    public static func saveAPIKey(_ value: String?) throws {
        guard let value, !value.isEmpty else {
            try deleteAPIKey()
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
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

    /// Returns the stored key, or `nil` if none has been saved.
    public static func readAPIKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw Error(status: status)
        }
    }

    /// Removes the stored key. A missing item is not an error.
    public static func deleteAPIKey() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Error(status: status)
        }
    }
}
