import RenderAPI
import SwiftUI

/// The Postgres list for the active owner: searchable, pull-to-refresh, and incremental paging as
/// you scroll. Tapping a row pushes the database detail screen.
struct PostgresListView: View {
    @State private var store: PostgresStore

    private let client: RenderClient
    /// Passed down to the detail screen: logs are addressed by workspace, not by database, so the
    /// owner has to travel with the database ID.
    private let ownerID: String

    init(client: RenderClient, ownerID: String, environmentIDs: [String]? = nil) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: PostgresStore(client: client, ownerID: ownerID, environmentIDs: environmentIDs))
    }

    var body: some View {
        List {
            ForEach(store.visibleDatabases) { database in
                row(for: database)
            }
            if store.hasMore && store.errorMessage == nil {
                loadingFooter
            }
        }
        .listStyle(.plain)
        .searchable(text: $store.searchText, prompt: "Search databases")
        .overlay { emptyState }
        .refreshable { await store.refresh() }
        .task { if store.databases.isEmpty { await store.refresh() } }
    }

    private func row(for database: PostgresSummary) -> some View {
        NavigationLink {
            PostgresDetailView(
                client: client,
                ownerID: ownerID,
                postgresID: database.id,
                databaseName: database.name
            )
        } label: {
            DatastoreRow(
                name: database.name,
                status: database.status,
                systemImage: "cylinder.split.1x2",
                accent: .blue,
                detailLine: "\(database.planDisplayName) · \(database.region.rawValue.capitalized) · Postgres \(database.version)",
                roleBadge: database.role == .replica ? "Replica" : nil
            )
        }
    }

    private var loadingFooter: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .listRowSeparator(.hidden)
        // onAppear (not .task) so it re-fires each time the footer scrolls back into view as pages
        // append. loadNextPage() is a no-op while a load is in flight or the list is exhausted.
        .onAppear { Task { await store.loadNextPage() } }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = store.errorMessage, store.databases.isEmpty {
            ErrorStateView(subject: "databases", message: message) { await store.refresh() }
        } else if store.databases.isEmpty && store.isLoading {
            SkeletonList()
        } else if store.databases.isEmpty {
            ContentUnavailableView(
                "No Postgres Databases",
                systemImage: "cylinder.split.1x2",
                description: Text(store.isProjectScoped ? "This project has no Postgres databases yet." : "This workspace has no Postgres databases yet.")
            )
        } else if store.visibleDatabases.isEmpty {
            // Loaded databases exist, but none match the current search.
            ContentUnavailableView.search
        }
    }
}
