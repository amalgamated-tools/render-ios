import Foundation
import Observation
import RenderAPI

/// A service as the list needs it. Domain projection of `Components.Schemas.Service` — the list
/// deliberately carries no deploy status (the payload has none); live health arrives in Phase 2.
struct ServiceSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: Components.Schemas.ServiceType
    let isSuspended: Bool
    let repo: String?
    let branch: String?
    let dashboardURL: URL?
    let updatedAt: Date

    init(_ service: Components.Schemas.Service) {
        self.id = service.id
        self.name = service.name
        self.type = service._type
        self.isSuspended = service.suspended == .suspended
        self.repo = service.repo
        self.branch = service.branch
        self.dashboardURL = URL(string: service.dashboardUrl)
        self.updatedAt = service.updatedAt
    }
}

/// Loads and pages the service list for one owner.
///
/// Fetches a page at a time (`CursorPaginator.firstPage`) and appends as the user scrolls. Search
/// and type filtering are applied client-side over the pages loaded so far — adequate for Phase 1;
/// a server-side `name`/`type` filter is a later refinement if lists grow large.
@MainActor
@Observable
final class ServicesStore {
    private(set) var services: [ServiceSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = true

    var searchText = ""
    var typeFilter: Components.Schemas.ServiceType?

    private let client: RenderClient
    private let ownerID: String
    private let environmentIDs: [String]?
    private let pageSize: Int
    private var nextCursor: String?

    /// - Parameter environmentIDs: The environments to restrict the list to, or `nil` for the whole
    ///   workspace. A project scope arrives here as the project's environments, since services
    ///   belong to environments rather than to projects.
    init(client: RenderClient, ownerID: String, environmentIDs: [String]? = nil, pageSize: Int = 50) {
        self.client = client
        self.ownerID = ownerID
        self.environmentIDs = environmentIDs
        self.pageSize = pageSize
    }

    /// Whether the list is narrowed to a project, which the empty state words differently.
    var isProjectScoped: Bool { environmentIDs != nil }

    /// Services after the active search text and type filter, sorted by name.
    var visibleServices: [ServiceSummary] {
        services
            .filter { typeFilter == nil || $0.type == typeFilter }
            .filter {
                let query = searchText.trimmingCharacters(in: .whitespaces)
                return query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Discards everything and reloads the first page. Backs pull-to-refresh and first appearance.
    func refresh() async {
        services = []
        nextCursor = nil
        hasMore = true
        errorMessage = nil
        await loadNextPage()
    }

    /// Loads the page after the current cursor. A no-op when a load is in flight or the list is
    /// exhausted, so it's safe to call from an on-appear handler on the last row.
    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        // A project with no environments holds no services, and an empty `environmentId` filter
        // would be sent as no filter at all — i.e. the entire workspace.
        if let environmentIDs, environmentIDs.isEmpty {
            hasMore = false
            return
        }
        isLoading = true
        defer { isLoading = false }

        let paginator = makePaginator()
        do {
            let page = try await paginator.firstPage(after: nextCursor)
            services.append(contentsOf: page.elements)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            hasMore = false
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.ServiceWithCursor, ServiceSummary> {
        let client = client
        let ownerID = ownerID
        let environmentIDs = environmentIDs
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                // PR previews are excluded by default — on a busy account they drown out the real
                // services this on-call view is for. A toggle to include them can come later.
                .listServices(query: .init(
                    environmentId: environmentIDs,
                    ownerId: [ownerID],
                    includePreviews: false,
                    cursor: cursor,
                    limit: limit
                ))
                .ok.body.json
        } unwrap: { envelope in
            (ServiceSummary(envelope.service), envelope.cursor)
        }
    }
}
