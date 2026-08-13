import Foundation
import Observation
import RenderAPI

/// Lists a workspace's env groups, and creates and deletes them.
///
/// **The list is workspace-wide, and deliberately ignores the active project scope**, unlike the
/// service list beside it. Two reasons, one of them a correctness argument:
/// - A group exists to be shared. It can be owned by the workspace and linked to services in several
///   projects, so filtering by `environmentId` would hide a group that a service in the current
///   project is *actually using* — the opposite of what the filter appears to promise.
/// - `environmentId` on a create is a single ID, and a project scope resolves to *several*
///   environments. Guessing one would file a new group under an environment nobody chose, and then
///   hide it from the list that created it.
///
/// So groups are created workspace-wide, which is also what the Dashboard's default is, and the list
/// says as much in its footer rather than leaving the absence of a filter to be noticed.
///
/// Paging is an ordinary `CursorPaginator`, but only after a spec patch: the vendored spec declares
/// this response as a bare array of `envGroupMeta`, while the live API returns the usual
/// `{envGroup, cursor}` envelope every other list endpoint uses. Since `envGroupMeta` marks six fields
/// required, the generated decoder **rejected every real reply** and this screen couldn't load at all —
/// found by the live pass, fixed in `Scripts/envelope-env-groups.py`, and watched by `Scripts/smoke.sh`.
@MainActor
@Observable
final class EnvGroupsStore {
    private(set) var groups: [EnvGroupSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    var searchText = ""

    private let client: RenderClient
    private let ownerID: String
    private let pageSize: Int

    init(client: RenderClient, ownerID: String, pageSize: Int = 100) {
        self.client = client
        self.ownerID = ownerID
        self.pageSize = pageSize
    }

    var sortedGroups: [EnvGroupSummary] {
        groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var visibleGroups: [EnvGroupSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sortedGroups }
        return sortedGroups.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    // MARK: - Reading

    /// Loads every group in scope. Drained rather than paged on scroll, for the same reason the config
    /// screens are: a workspace has tens of groups, and a partial list of shared configuration invites
    /// someone to create a second group that already exists.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            groups = try await makePaginator().collect()
            errorMessage = nil
        } catch {
            // Keep whatever is on screen: the difference between "no groups" and "we couldn't ask"
            // matters as much here as it does on a config screen.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    // MARK: - Writing

    /// Creates an empty group in the current scope.
    ///
    /// Empty on purpose: the variables go in on the next screen, through the same editor that edits an
    /// existing group's, rather than through a second one built into a create form.
    @discardableResult
    func create(name: String) async -> EnvGroupSummary? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, writeInFlight == nil else { return nil }

        writeInFlight = name
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            // No `environmentId`: workspace-wide, for the reasons in this type's note. No
            // `serviceIds` either — linking is done from the group's own screen, where the user can
            // see what they're attaching it to.
            let created = try await client.api.createEnvGroup(
                body: .json(.init(name: name, ownerId: ownerID, envVars: []))
            ).created.body.json
            let group = EnvGroupSummary(created)
            groups.append(group)
            actionResult = .success("\(group.name) created.")
            return group
        } catch {
            actionResult = .failure(error)
            return nil
        }
    }

    /// Deletes a group. Confirmed in the UI, and the confirmation names how many services it feeds.
    @discardableResult
    func delete(_ group: EnvGroupSummary) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = group.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await client.api.deleteEnvGroup(path: .init(envGroupId: group.id)).expectSuccess()
            groups.removeAll { $0.id == group.id }
            actionResult = .success("\(group.name) deleted.")
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Folds a group the detail screen changed back into the list, so a rename or a link doesn't need
    /// a full reload to show up behind it.
    func apply(_ group: EnvGroupSummary) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    func containsName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return groups.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.EnvGroupWithCursor, EnvGroupSummary> {
        let client = client
        let ownerID = ownerID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listEnvGroups(query: .init(ownerId: [ownerID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            (EnvGroupSummary(envelope.envGroup), envelope.cursor)
        }
    }
}
