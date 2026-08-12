import RenderAPI
import SwiftUI

/// The service list for the active owner: searchable, filterable by type, pull-to-refresh, and
/// incremental paging as you scroll. Tapping a row pushes the service detail screen.
struct ServicesListView: View {
    @State private var store: ServicesStore

    private let client: RenderClient

    init(client: RenderClient, ownerID: String) {
        self.client = client
        _store = State(initialValue: ServicesStore(client: client, ownerID: ownerID))
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
    }

    private func row(for service: ServiceSummary) -> some View {
        NavigationLink {
            ServiceDetailView(client: client, serviceID: service.id, serviceName: service.name)
        } label: {
            ServiceRow(service: service)
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
            ContentUnavailableView {
                Label("Couldn't load services", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await store.refresh() } }
            }
        } else if store.services.isEmpty && store.isLoading {
            ProgressView()
        } else if store.services.isEmpty {
            ContentUnavailableView(
                "No Services",
                systemImage: "server.rack",
                description: Text("This workspace has no services yet.")
            )
        } else if store.visibleServices.isEmpty {
            // Loaded services exist, but none match the current search/filter.
            ContentUnavailableView.search
        }
    }
}
