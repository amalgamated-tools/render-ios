import Foundation

/// An organization ID and the Audit Log API key that reads its audit log.
///
/// Render issues these keys separately from personal API keys, from the organization's settings,
/// and each one reads only the organization it was created in. No endpoint returns organization
/// IDs, so the user supplies both.
public struct OrgAuditLogCredential: Codable, Sendable, Hashable {
    public let organizationID: String
    public let apiKey: String

    public init(organizationID: String, apiKey: String) {
        self.organizationID = organizationID
        self.apiKey = apiKey
    }
}

/// Persistence seam for ``OrgAuditLogCredential``, so the app can be tested without the Keychain.
public protocol OrgAuditLogCredentialStoring: Sendable {
    func read() throws -> OrgAuditLogCredential?
    /// `nil` deletes any stored credential.
    func write(_ credential: OrgAuditLogCredential?) throws
}

/// The production store.
public struct KeychainOrgAuditLogCredentialStore: OrgAuditLogCredentialStoring {
    public init() {}

    public func read() throws -> OrgAuditLogCredential? {
        try Keychain.readOrgAuditLogCredential()
    }

    public func write(_ credential: OrgAuditLogCredential?) throws {
        try Keychain.saveOrgAuditLogCredential(credential)
    }
}
