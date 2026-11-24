import Foundation
import Observation
import RenderAPI

/// A project as the scope picker needs it. Domain projection of `Components.Schemas.Project`.
struct ProjectSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Services belong to *environments*, not to projects directly, so scoping the service list to
    /// a project means filtering on every environment the project owns.
    let environmentIDs: [String]

    init(_ project: Components.Schemas.Project) {
        self.id = project.id
        self.name = project.name
        self.environmentIDs = project.environmentIds
    }

    init(id: String, name: String, environmentIDs: [String]) {
        self.id = id
        self.name = name
        self.environmentIDs = environmentIDs
    }
}

/// Loads the projects of one owner and remembers which one the service list is scoped to.
///
/// Projects are few (tens, not thousands), so the whole list is drained up front and held for the
/// picker — unlike services, which page as you scroll.
@MainActor
@Observable
final class ProjectsStore {
    private(set) var projects: [ProjectSummary] = []
    private(set) var errorMessage: String?
    /// False until the first load settles. A remembered project can't be resolved to its
    /// environments before then, so the service list has to wait rather than briefly load the
    /// whole workspace under a project's name.
    private(set) var hasLoaded = false
    private(set) var isCreating = false
    /// The outcome of the last create or delete, for the Projects list's banner.
    private(set) var actionResult: ProjectActionResult?

    /// `nil` means "all projects" — the unscoped workspace-wide list. Persisted per owner (and
    /// non-secret) so the app reopens on the same scope.
    var selectedProjectID: String? {
        didSet { defaults.set(selectedProjectID, forKey: Self.defaultsKey(ownerID)) }
    }

    private let client: RenderClient
    private let ownerID: String
    private let defaults: UserDefaults
    /// Bumped by every load, so an older load that finishes late can't overwrite a newer one.
    private var generation = 0
    /// Changes made since the current load started. Each is newer than anything that load
    /// fetched, so they're applied over its result rather than lost to it.
    private var changedSinceLoad: [String: ProjectSummary] = [:]
    private var createdSinceLoad: [ProjectSummary] = []
    private var removedSinceLoad: Set<String> = []

    /// - Parameter defaults: Injection seam for tests, so a test run doesn't leave a scope behind
    ///   in the app's own defaults.
    init(client: RenderClient, ownerID: String, defaults: UserDefaults = .standard) {
        self.client = client
        self.ownerID = ownerID
        self.defaults = defaults
        self.selectedProjectID = defaults.string(forKey: Self.defaultsKey(ownerID))
    }

    var selectedProject: ProjectSummary? {
        projects.first { $0.id == selectedProjectID }
    }

    /// The `environmentId` filter for the service list: `nil` when unscoped, which the API reads as
    /// "no filter".
    var selectedEnvironmentIDs: [String]? {
        selectedProject?.environmentIDs
    }

    /// Identifies the current scope for the scoped lists' `.id`. It changes when the selected
    /// project gains or loses an environment, not only when another project is picked, so those
    /// lists rebuild their stores with the new filter.
    var selectedScopeKey: String {
        guard let selectedProjectID else { return "" }
        return ([selectedProjectID] + (selectedEnvironmentIDs ?? [])).joined(separator: ",")
    }

    /// Loads every project for the owner. A failure is non-fatal: the projects already shown stay.
    /// On a first load that means the picker offers none, and the service list stays workspace-wide.
    func load() async {
        generation += 1
        let current = generation
        // A load starting now fetches after any earlier change, so it has nothing to apply over it.
        changedSinceLoad = [:]
        createdSinceLoad = []
        removedSinceLoad = []
        errorMessage = nil
        let paginator = CursorPaginator(pageSize: 100) { [client, ownerID] cursor, limit in
            try await client.api
                .listProjects(query: .init(ownerId: [ownerID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { (envelope: Components.Schemas.ProjectWithCursor) in
            (ProjectSummary(envelope.project), envelope.cursor)
        }
        do {
            let listed = try await paginator.collect()
            guard current == generation else { return }
            var merged = listed
                .filter { !removedSinceLoad.contains($0.id) }
                .map { changedSinceLoad[$0.id] ?? $0 }
            // Created entries get the same overrides: one may have been renamed since.
            merged += createdSinceLoad
                .filter { created in !removedSinceLoad.contains(created.id) && !merged.contains { $0.id == created.id } }
                .map { changedSinceLoad[$0.id] ?? $0 }
            projects = merged
            sortProjects()
            // A remembered project that's been deleted (or belongs to another workspace) would
            // otherwise scope the list to a filter the user can't see or clear.
            if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
                self.selectedProjectID = nil
            }
        } catch {
            guard current == generation else { return }
            // Keep what's shown, including anything created while this load ran. A failed refresh
            // shouldn't drop the projects, or the remembered scope with them.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
        hasLoaded = true
    }

    private func sortProjects() {
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Takes a rename made on a project's screen, so the picker and the Projects list show it
    /// without a reload.
    func replace(_ project: ProjectSummary) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        changedSinceLoad[project.id] = project
        sortProjects()
    }

    /// Creates a project with one environment. Render requires a project to start with its
    /// environments listed, and a project with none has nowhere to put anything.
    /// - Returns: The new project, or `nil` when Render refused it (the reason is in `actionResult`).
    func create(name: String, environmentName: String) async -> ProjectSummary? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentName = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isCreating, !name.isEmpty, !environmentName.isEmpty else { return nil }
        isCreating = true
        actionResult = nil
        defer { isCreating = false }
        do {
            let created = try await client.api.createProject(body: .json(.init(
                name: name,
                ownerId: ownerID,
                environments: [.init(name: environmentName)]
            ))).created.body.json
            let project = ProjectSummary(created)
            // A load that finished while this request was out may already list it.
            projects.removeAll { $0.id == project.id }
            projects.append(project)
            createdSinceLoad.append(project)
            sortProjects()
            actionResult = ProjectActionResult(message: "Created \(project.name).", isFailure: false)
            return project
        } catch {
            actionResult = .failure(error)
            return nil
        }
    }

    /// Takes a project deleted on its own screen out of the list, and out of the scope picker.
    func remove(_ project: ProjectSummary) {
        projects.removeAll { $0.id == project.id }
        removedSinceLoad.insert(project.id)
        createdSinceLoad.removeAll { $0.id == project.id }
        changedSinceLoad[project.id] = nil
        // Otherwise the service list stays scoped to environments that no longer exist.
        if selectedProjectID == project.id { selectedProjectID = nil }
        actionResult = ProjectActionResult(message: "Deleted \(project.name).", isFailure: false)
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private static func defaultsKey(_ ownerID: String) -> String {
        "selectedProjectID.\(ownerID)"
    }
}
