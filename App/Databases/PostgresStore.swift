import Foundation
import Observation
import RenderAPI

/// A Postgres instance as the list needs it. Domain projection of `Components.Schemas.Postgres`.
struct PostgresSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: Components.Schemas.DatabaseStatus
    let isSuspended: Bool
    let role: Components.Schemas.DatabaseRole
    let isHighAvailabilityEnabled: Bool
    let planDisplayName: String
    let region: Components.Schemas.Region
    let version: String
    let dashboardURL: URL?
    let updatedAt: Date

    init(_ postgres: Components.Schemas.Postgres) {
        self.id = postgres.id
        self.name = postgres.name
        self.status = postgres.status
        self.isSuspended = postgres.suspended == .suspended
        self.role = postgres.role
        self.isHighAvailabilityEnabled = postgres.highAvailabilityEnabled
        self.planDisplayName = datastorePlanDisplayName(postgres.plan.rawValue)
        self.region = postgres.region
        self.version = postgres.version.rawValue
        self.dashboardURL = URL(string: postgres.dashboardUrl)
        self.updatedAt = postgres.updatedAt
    }
}

/// `basic_1gb` → `Basic 1gb`. One helper for every datastore plan spelling, because the generated
/// plan enums are distinct nested types per schema (`Postgres.PlanPayload`, `PostgresDetail.PlanPayload`,
/// `KeyValuePlan`) — a shared enum can't exist, but a shared formatting rule can.
func datastorePlanDisplayName(_ raw: String) -> String {
    raw.replacingOccurrences(of: "_", with: " ").capitalized
}

/// Loads and pages the Postgres list for one owner. Same shape as `ServicesStore`: a page at a
/// time via `CursorPaginator.firstPage`, with search applied client-side over the pages loaded
/// so far.
@MainActor
@Observable
final class PostgresStore {
    private(set) var databases: [PostgresSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = true

    var searchText = ""

    private let client: RenderClient
    private let ownerID: String
    private let environmentIDs: [String]?
    private let pageSize: Int
    private var nextCursor: String?

    /// - Parameter environmentIDs: The environments to restrict the list to, or `nil` for the whole
    ///   workspace. A project scope arrives here as the project's environments.
    init(client: RenderClient, ownerID: String, environmentIDs: [String]? = nil, pageSize: Int = 50) {
        self.client = client
        self.ownerID = ownerID
        self.environmentIDs = environmentIDs
        self.pageSize = pageSize
    }

    /// Whether the list is narrowed to a project, which the empty state words differently.
    var isProjectScoped: Bool { environmentIDs != nil }

    /// Databases after the active search text, sorted by name.
    var visibleDatabases: [PostgresSummary] {
        databases
            .filter {
                let query = searchText.trimmingCharacters(in: .whitespaces)
                return query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Discards everything and reloads the first page. Backs pull-to-refresh and first appearance.
    func refresh() async {
        databases = []
        nextCursor = nil
        hasMore = true
        errorMessage = nil
        await loadNextPage()
    }

    /// Loads the page after the current cursor. A no-op when a load is in flight or the list is
    /// exhausted, so it's safe to call from an on-appear handler on the last row.
    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        // A project with no environments holds no databases, and an empty `environmentId` filter
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
            databases.append(contentsOf: page.elements)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            hasMore = false
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.PostgresWithCursor, PostgresSummary> {
        let client = client
        let ownerID = ownerID
        let environmentIDs = environmentIDs
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                // Replicas are listed alongside primaries — the row's role badge tells them apart,
                // and hiding them would make a workspace look smaller than its bill.
                .listPostgres(query: .init(
                    ownerId: [ownerID],
                    environmentId: environmentIDs,
                    includeReplicas: true,
                    cursor: cursor,
                    limit: limit
                ))
                .ok.body.json
        } unwrap: { envelope in
            (PostgresSummary(envelope.postgres), envelope.cursor)
        }
    }
}
