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

    /// `nil` means "all projects" — the unscoped workspace-wide list. Persisted per owner (and
    /// non-secret) so the app reopens on the same scope.
    var selectedProjectID: String? {
        didSet { defaults.set(selectedProjectID, forKey: Self.defaultsKey(ownerID)) }
    }

    private let client: RenderClient
    private let ownerID: String
    private let defaults: UserDefaults

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

    /// Loads every project for the owner. A failure is non-fatal: the picker just doesn't offer
    /// projects, and the service list stays workspace-wide.
    func load() async {
        errorMessage = nil
        defer { hasLoaded = true }
        let paginator = CursorPaginator(pageSize: 100) { [client, ownerID] cursor, limit in
            try await client.api
                .listProjects(query: .init(ownerId: [ownerID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { (envelope: Components.Schemas.ProjectWithCursor) in
            (ProjectSummary(envelope.project), envelope.cursor)
        }
        do {
            projects = try await paginator.collect()
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            // A remembered project that's been deleted (or belongs to another workspace) would
            // otherwise scope the list to a filter the user can't see or clear.
            if let selectedProjectID, !projects.contains(where: { $0.id == selectedProjectID }) {
                self.selectedProjectID = nil
            }
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            projects = []
        }
    }

    /// Takes a rename made on a project's screen, so the picker and the Projects list show it
    /// without a reload.
    func replace(_ project: ProjectSummary) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
        projects.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func defaultsKey(_ ownerID: String) -> String {
        "selectedProjectID.\(ownerID)"
    }
}
