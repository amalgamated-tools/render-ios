import RenderAPI
import SwiftUI

/// The service list for the active owner: searchable, filterable by type, pull-to-refresh, and
/// incremental paging as you scroll. Tapping a row pushes the service detail screen.
struct ServicesListView: View {
    @State private var store: ServicesStore
    @State private var watchlistFullMessage: String?
    @Environment(FailureWatchCoordinator.self) private var coordinator

    private let client: RenderClient
    /// Passed down to the detail screen: logs are addressed by workspace, not by service, so the
    /// owner has to travel with the service ID.
    private let ownerID: String

    init(client: RenderClient, ownerID: String, environmentIDs: [String]? = nil) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: ServicesStore(client: client, ownerID: ownerID, environmentIDs: environmentIDs))
    }

    var body: some View {
        List {
            ForEach(store.visibleServices) { service in
                row(for: service)
            }
            if store.hasMore && store.errorMessage == nil {
                loadingFooter
            }
        }
        .listStyle(.plain)
        .searchable(text: $store.searchText, prompt: "Search services")
        .toolbar { typeFilterMenu }
        .overlay { emptyState }
        .refreshable { await store.refresh() }
        .task { if store.services.isEmpty { await store.refresh() } }
        .alert(
            "Watchlist Full",
            isPresented: .init(get: { watchlistFullMessage != nil }, set: { if !$0 { watchlistFullMessage = nil } }),
            presenting: watchlistFullMessage
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    /// The destination is a value rather than a view, so a tapped notification can push the same
    /// screen — see ``ServiceRoute``. `WorkspaceScreen` owns the matching `navigationDestination`,
    /// because it owns the stack.
    private func row(for service: ServiceSummary) -> some View {
        NavigationLink(value: ServiceRoute(id: service.id, name: service.name)) {
            ServiceRow(service: service, isWatched: coordinator.watchlist.isWatching(service.id))
        }
        .swipeActions(edge: .trailing) {
            let isWatched = coordinator.watchlist.isWatching(service.id)
            Button {
                Task { await toggleWatch(service, isWatched: isWatched) }
            } label: {
                Label(
                    isWatched ? "Stop Watching" : "Watch",
                    systemImage: isWatched ? "bell.slash" : "bell"
                )
            }
            .tint(isWatched ? .secondary : .accentColor)
        }
    }

    private func toggleWatch(_ service: ServiceSummary, isWatched: Bool) async {
        if isWatched {
            coordinator.unwatch(serviceID: service.id)
        } else if await coordinator.watch(serviceID: service.id, ownerID: ownerID, name: service.name) == false {
            watchlistFullMessage = "You can watch up to \(WatchlistStore.limit) services. Stop watching one to add another."
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

    @ToolbarContentBuilder
    private var typeFilterMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Type", selection: $store.typeFilter) {
                    Text("All Types").tag(Components.Schemas.ServiceType?.none)
                    ForEach(Components.Schemas.ServiceType.allCases, id: \.self) { type in
                        Label(type.displayName, systemImage: type.systemImage)
                            .tag(Components.Schemas.ServiceType?.some(type))
                    }
                }
            } label: {
                Label("Filter", systemImage: store.typeFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = store.errorMessage, store.services.isEmpty {
            ErrorStateView(subject: "services", message: message) { await store.refresh() }
        } else if store.services.isEmpty && store.isLoading {
            SkeletonList()
        } else if store.services.isEmpty {
            ContentUnavailableView(
                "No Services",
                systemImage: "server.rack",
                description: Text(store.isProjectScoped ? "This project has no services yet." : "This workspace has no services yet.")
            )
        } else if store.visibleServices.isEmpty {
            // Loaded services exist, but none match the current search/filter.
            ContentUnavailableView.search
        }
    }
}
