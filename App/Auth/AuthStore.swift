import Foundation
import Observation
import RenderAPI

/// A Render account/team the API key can act as. Domain projection of `Components.Schemas.Owner`,
/// so views never touch generated types.
struct OwnerSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let email: String
    let isTeam: Bool
}

/// Owns authentication state for the whole app: the API key (in the Keychain, never here), the list
/// of owners the key can act as, and which one is selected.
///
/// The key is validated by calling `listOwners` — a successful call proves the key works *and*
/// yields the workspace list in one round trip. A key is only written to the Keychain **after** it
/// validates, so a typo never displaces a working key.
@MainActor
@Observable
final class AuthStore {
    enum Phase: Equatable {
        /// Launch-time silent revalidation of a stored key — shows a splash, not onboarding.
        case restoring
        /// No usable key: show onboarding.
        case needsKey
        /// Validating a key the user just entered: onboarding stays up, showing a busy state.
        case authenticating
        /// Key is good; show the service list.
        case authenticated
    }

    private(set) var phase: Phase = .restoring
    private(set) var owners: [OwnerSummary] = []
    private(set) var errorMessage: String?

    /// Persisted (non-secret) so the app reopens on the same workspace. Only the API key is secret.
    var selectedOwnerID: String? {
        didSet {
            UserDefaults.standard.set(selectedOwnerID, forKey: Self.selectedOwnerKey)
        }
    }

    private static let selectedOwnerKey = "selectedOwnerID"
    private let makeClient: @Sendable (any APIKeyProvider) -> RenderClient

    /// - Parameter makeClient: Injection seam for tests/previews; production builds the real client.
    init(makeClient: @escaping @Sendable (any APIKeyProvider) -> RenderClient = { RenderClient(apiKeyProvider: $0) }) {
        self.makeClient = makeClient
        self.selectedOwnerID = UserDefaults.standard.string(forKey: Self.selectedOwnerKey)
    }

    /// A client bound to the persisted Keychain key, for feature stores to use once authenticated.
    func authenticatedClient() -> RenderClient {
        makeClient(KeychainAPIKeyProvider())
    }

    /// Called on launch: if a key is already stored, revalidate it silently; otherwise onboard.
    func restore() async {
        let stored = (try? Keychain.readAPIKey()) ?? nil
        guard stored != nil else {
            phase = .needsKey
            return
        }
        phase = .restoring
        await loadOwners(using: KeychainAPIKeyProvider(), persisting: nil)
    }

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

    /// Clears the key and returns to onboarding.
    func signOut() {
        try? Keychain.saveAPIKey(nil)
        owners = []
        selectedOwnerID = nil
        errorMessage = nil
        phase = .needsKey
    }

    private func loadOwners(using provider: any APIKeyProvider, persisting key: String?) async {
        let client = makeClient(provider)
        do {
            let owners = try await Self.fetchOwners(client)
            // Persist only after the key proves good.
            if let key { try? Keychain.saveAPIKey(key) }
            self.owners = owners
            if selectedOwnerID == nil || !owners.contains(where: { $0.id == selectedOwnerID }) {
                selectedOwnerID = owners.first?.id
            }
            phase = .authenticated
        } catch {
            let renderError = RenderError.wrapping(error)
            // A stored-but-now-invalid key should drop us to onboarding with the key cleared.
            if renderError.requiresReauthentication { try? Keychain.saveAPIKey(nil) }
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
}
