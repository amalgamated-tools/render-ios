import Foundation
import Observation
import RenderAPI

/// The organization ID and Audit Log API key for the organization audit log.
///
/// A personal API key can't read an organization's audit log: Render answers 403 even for the
/// organization's own admin. It takes a separate read-only Audit Log API key, created in the
/// organization's settings, and no endpoint lists organizations, so the user enters both. A pair is
/// saved only after Render accepts it, the way a pasted sign-in key is.
@MainActor
@Observable
final class OrgAuditLogSettings {
    private(set) var credential: OrgAuditLogCredential?
    private(set) var isVerifying = false
    private(set) var errorMessage: String?

    private let store: any OrgAuditLogCredentialStoring
    private let makeClient: @Sendable (String) -> RenderClient

    init(
        store: any OrgAuditLogCredentialStoring = KeychainOrgAuditLogCredentialStore(),
        makeClient: @escaping @Sendable (String) -> RenderClient = {
            RenderClient(apiKeyProvider: StaticAPIKeyProvider($0))
        }
    ) {
        self.store = store
        self.makeClient = makeClient
        credential = (try? store.read()) ?? nil
    }

    /// Checks the pair with one read of the log and saves it if Render answers. Returns whether it saved.
    @discardableResult
    func save(organizationID: String, apiKey: String) async -> Bool {
        let id = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasPrefix("org-"), id.count > 4 else {
            errorMessage = "An organization ID starts with \"org-\". It's in the organization's settings in the Render Dashboard."
            return false
        }
        guard !key.isEmpty else {
            errorMessage = "Enter the Audit Log API key."
            return false
        }
        guard !isVerifying else { return false }
        isVerifying = true
        defer { isVerifying = false }
        let scope = AuditLogStore.Scope.organization(id: id)
        do {
            _ = try await AuditLogStore.fetch(client: makeClient(key), scope: scope, cursor: nil, limit: 1)
        } catch {
            errorMessage = AuditLogStore.describe(error, scope: scope)
            return false
        }
        let credential = OrgAuditLogCredential(organizationID: id, apiKey: key)
        do {
            try store.write(credential)
        } catch {
            errorMessage = "The key works, but it couldn't be saved on this device."
            return false
        }
        self.credential = credential
        errorMessage = nil
        return true
    }

    /// Deletes the saved pair from this device. The key itself stays valid until it's revoked in Render.
    func remove() {
        try? store.write(nil)
        credential = nil
        errorMessage = nil
    }

    /// A log store for the saved organization, with its own client carrying the Audit Log API key.
    func makeLogStore(pageSize: Int = 50) -> AuditLogStore? {
        guard let credential else { return nil }
        return AuditLogStore(
            client: makeClient(credential.apiKey),
            scope: .organization(id: credential.organizationID),
            pageSize: pageSize
        )
    }
}
