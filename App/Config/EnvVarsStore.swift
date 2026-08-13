import Foundation
import Observation
import RenderAPI

/// One environment variable, as the screen needs it.
struct EnvVarEntry: Identifiable, Hashable, Sendable {
    /// The key *is* the identity: Render addresses env vars by key, not by an opaque ID.
    var id: String { key }
    let key: String
    let value: String

    init(key: String, value: String) {
        self.key = key
        self.value = value
    }

    init(_ envVar: Components.Schemas.EnvVar) {
        self.init(key: envVar.key, value: envVar.value)
    }
}

/// Reads and writes a service's environment variables.
///
/// **Writes go key by key, never as a whole-list PUT.** The API offers both — `PUT
/// /services/{id}/env-vars` replaces the entire set — and the whole-list form is a lost-update
/// hazard: it would silently delete anything added from the dashboard (or by a teammate) since this
/// screen last loaded. `PUT /services/{id}/env-vars/{key}` is create-or-update on one key, so
/// editing `LOG_LEVEL` from a phone can't take a colleague's new variable down with it.
///
/// **A write does not deploy.** Render applies an API env var change to the service's configuration
/// immediately, but — unlike the same edit made in the dashboard — it does not start a deploy, so the
/// running instances keep the old value until the next one. Verified live: writing and deleting a
/// variable produced no deploy and no deploy event. The UI says so, because "saved" that silently
/// means "not live yet" is the kind of thing you find out at 3am.
@MainActor
@Observable
final class EnvVarsStore {
    private(set) var entries: [EnvVarEntry] = []
    private(set) var isLoading = false
    /// Set when the list itself couldn't be read — the screen has nothing to show.
    private(set) var errorMessage: String?
    /// The key currently being written, so its row can show progress and the form can disable.
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    /// Filters the loaded list client-side. Every variable is already in memory, so this is instant
    /// and there is no server-side search to prefer.
    var searchText = ""

    /// Starts a deploy from the success banner, since a saved variable isn't a live one. `nil` when
    /// the service can't be deployed, and the banner then only reports.
    let deployer: ConfigDeployer?

    private let client: RenderClient
    private let serviceID: String
    private let pageSize: Int

    init(
        client: RenderClient,
        serviceID: String,
        deployer: ConfigDeployer? = nil,
        pageSize: Int = 100
    ) {
        self.client = client
        self.serviceID = serviceID
        self.deployer = deployer
        self.pageSize = pageSize
    }

    /// Entries in the order they're displayed: alphabetical by key, which is the only order that
    /// makes a list of thirty variables scannable. Render returns them in its own order.
    var sortedEntries: [EnvVarEntry] {
        entries.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    /// The rows to draw: sorted, then narrowed by the search text.
    ///
    /// Matching is on the **key only**. Searching values would mean the app comparing against
    /// secrets the user has deliberately kept masked, and a hit would reveal by implication which
    /// variable holds the string typed into the search field.
    var visibleEntries: [EnvVarEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sortedEntries }
        return sortedEntries.filter { $0.key.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Reading

    /// Loads every variable. Unlike the service list this drains the whole collection rather than
    /// paging on scroll: a service has tens of variables, not hundreds, and a config screen that
    /// shows *some* of the configuration would be a trap.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            entries = try await makePaginator().collect()
            errorMessage = nil
        } catch {
            // Keep whatever is already on screen: a failed refresh is a reason to say so, not a
            // reason to blank a list the user may be reading.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    // MARK: - Writing

    /// Creates or updates one variable.
    ///
    /// - Returns: `true` when Render accepted it, so the caller can dismiss its editor only on
    ///   success and leave the user's typing intact otherwise.
    @discardableResult
    func save(key: String, value: String) async -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, writeInFlight == nil else { return false }

        writeInFlight = key
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let updated = try await client.api.updateEnvVar(
                path: .init(serviceId: serviceID, envVarKey: key),
                body: .json(.EnvVarValue(.init(value: value)))
            ).ok.body.json
            // Apply the *response*, not the request: Render is the authority on what it stored.
            apply(EnvVarEntry(updated))
            actionResult = .success(
                "\(key) saved. It takes effect on the next deploy.",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Deletes one variable.
    @discardableResult
    func delete(key: String) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = key
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            _ = try await client.api.deleteEnvVar(
                path: .init(serviceId: serviceID, envVarKey: key)
            ).noContent
            entries.removeAll { $0.key == key }
            actionResult = .success(
                "\(key) deleted. It takes effect on the next deploy.",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Deploys the service, so the change the banner is reporting becomes the one that's running.
    func deployNow() async {
        guard writeInFlight == nil, let deployer else { return }
        if let result = await deployer.deploy() {
            actionResult = result
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    /// Whether a key would overwrite something that already exists — the editor words its button
    /// "Save" vs "Add" from this, since a create and an update are the same request.
    func containsKey(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.contains { $0.key == key }
    }

    private func apply(_ entry: EnvVarEntry) {
        if let index = entries.firstIndex(where: { $0.key == entry.key }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.EnvVarWithCursor, EnvVarEntry> {
        let client = client
        let serviceID = serviceID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .getEnvVarsForService(
                    path: .init(serviceId: serviceID),
                    query: .init(cursor: cursor, limit: limit)
                )
                .ok.body.json
        } unwrap: { envelope in
            (EnvVarEntry(envelope.envVar), envelope.cursor)
        }
    }
}
