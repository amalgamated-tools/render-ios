import RenderAPI
import SwiftUI

/// The Key Value list for the active owner: searchable, pull-to-refresh, and incremental paging as
/// you scroll. Tapping a row pushes the instance detail screen.
struct KeyValueListView: View {
    @State private var store: KeyValueStore

    private let client: RenderClient
    /// Passed down to the detail screen: logs are addressed by workspace, not by instance, so the
    /// owner has to travel with the instance ID.
    private let ownerID: String

    init(client: RenderClient, ownerID: String, environmentIDs: [String]? = nil) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: KeyValueStore(client: client, ownerID: ownerID, environmentIDs: environmentIDs))
    }

    var body: some View {
        List {
            ForEach(store.visibleInstances) { instance in
                row(for: instance)
            }
            if store.hasMore && store.errorMessage == nil {
                loadingFooter
            }
        }
        .listStyle(.plain)
        .searchable(text: $store.searchText, prompt: "Search instances")
        .overlay { emptyState }
        .refreshable { await store.refresh() }
        .task { if store.instances.isEmpty { await store.refresh() } }
    }

    private func row(for instance: KeyValueSummary) -> some View {
        NavigationLink {
            KeyValueDetailView(
                client: client,
                ownerID: ownerID,
                keyValueID: instance.id,
                instanceName: instance.name,
                // The detail schema has no dashboardUrl, so the list's copy travels with the push.
                dashboardURL: instance.dashboardURL
            )
        } label: {
            DatastoreRow(
                name: instance.name,
                status: instance.status,
                systemImage: "bolt.horizontal.circle",
                accent: .red,
                detailLine: "\(instance.planDisplayName) · \(instance.region.rawValue.capitalized) · Valkey \(instance.version)"
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
        if let message = store.errorMessage, store.instances.isEmpty {
            ErrorStateView(subject: "instances", message: message) { await store.refresh() }
        } else if store.instances.isEmpty && store.isLoading {
            SkeletonList()
        } else if store.instances.isEmpty {
            ContentUnavailableView(
                "No Key Value Instances",
                systemImage: "bolt.horizontal.circle",
                description: Text(store.isProjectScoped ? "This project has no Key Value instances yet." : "This workspace has no Key Value instances yet.")
            )
        } else if store.visibleInstances.isEmpty {
            // Loaded instances exist, but none match the current search.
            ContentUnavailableView.search
        }
    }
}
