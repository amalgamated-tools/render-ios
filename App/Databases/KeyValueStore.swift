import Foundation
import Observation
import RenderAPI

/// A Key Value instance as the list needs it. Domain projection of `Components.Schemas.KeyValue`.
///
/// Unlike Postgres, the schema carries no `suspended` field — suspension is only visible as
/// `status == .suspended` — and the *detail* schema carries no `dashboardUrl`, so the list's copy
/// travels into the detail screen.
struct KeyValueSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: Components.Schemas.DatabaseStatus
    let planDisplayName: String
    let region: Components.Schemas.Region
    let version: String
    let dashboardURL: URL?
    let updatedAt: Date

    init(_ keyValue: Components.Schemas.KeyValue) {
        self.id = keyValue.id
        self.name = keyValue.name
        self.status = keyValue.status
        self.planDisplayName = datastorePlanDisplayName(keyValue.plan.rawValue)
        self.region = keyValue.region
        self.version = keyValue.version
        self.dashboardURL = URL(string: keyValue.dashboardUrl)
        self.updatedAt = keyValue.updatedAt
    }
}

/// Loads and pages the Key Value list for one owner. Same shape as `PostgresStore`.
@MainActor
@Observable
final class KeyValueStore {
    private(set) var instances: [KeyValueSummary] = []
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

    /// Instances after the active search text, sorted by name.
    var visibleInstances: [KeyValueSummary] {
        instances
            .filter {
                let query = searchText.trimmingCharacters(in: .whitespaces)
                return query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Discards everything and reloads the first page. Backs pull-to-refresh and first appearance.
    func refresh() async {
        instances = []
        nextCursor = nil
        hasMore = true
        errorMessage = nil
        await loadNextPage()
    }

    /// Loads the page after the current cursor. A no-op when a load is in flight or the list is
    /// exhausted, so it's safe to call from an on-appear handler on the last row.
    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        // A project with no environments holds no instances, and an empty `environmentId` filter
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
            instances.append(contentsOf: page.elements)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            hasMore = false
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.KeyValueWithCursor, KeyValueSummary> {
        let client = client
        let ownerID = ownerID
        let environmentIDs = environmentIDs
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listKeyValue(query: .init(
                    ownerId: [ownerID],
                    environmentId: environmentIDs,
                    cursor: cursor,
                    limit: limit
                ))
                .ok.body.json
        } unwrap: { envelope in
            (KeyValueSummary(envelope.keyValue), envelope.cursor)
        }
    }
}
