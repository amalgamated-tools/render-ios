import RenderAPI
import SwiftUI

/// Deploy history for one service, newest first, paging as you scroll.
///
/// Owns the rollback flow: the candidate has to be picked from history, so the confirmation and the
/// outcome banner both belong here rather than on the detail screen behind it. The action itself goes
/// through the detail screen's `ServiceDetailStore`, so one place still owns "what did we just ask
/// Render to do".
struct DeploysListView: View {
    @State private var deploysStore: DeploysStore
    @State private var pendingRollback: DeploySummary?

    private let client: RenderClient
    private let store: ServiceDetailStore

    init(client: RenderClient, store: ServiceDetailStore) {
        self.client = client
        self.store = store
        _deploysStore = State(initialValue: DeploysStore(client: client, serviceID: store.serviceID))
    }

    var body: some View {
        List {
            ForEach(deploysStore.deploys) { deploy in
                NavigationLink {
                    DeployDetailView(client: client, serviceID: store.serviceID, deploy: deploy)
                } label: {
                    DeployRow(deploy: deploy)
                }
                .swipeActions(edge: .leading) {
                    if deploy.isRollbackCandidate {
                        Button("Roll Back", systemImage: "arrow.uturn.backward") {
                            pendingRollback = deploy
                        }
                        .tint(.orange)
                    }
                }
            }
            if deploysStore.hasMore && deploysStore.errorMessage == nil {
                loadingFooter
            }
        }
        .listStyle(.plain)
        .navigationTitle("Deploys")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await deploysStore.refresh() }
        .task { if deploysStore.deploys.isEmpty { await deploysStore.refresh() } }
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) { banner }
        .confirmationDialog(
            pendingRollback.map { rollbackAction(for: $0).confirmationTitle(serviceName: serviceName) } ?? "",
            isPresented: .init(get: { pendingRollback != nil }, set: { if !$0 { pendingRollback = nil } }),
            titleVisibility: .visible,
            presenting: pendingRollback
        ) { deploy in
            Button("Roll Back", role: .destructive) {
                Task {
                    await store.perform(rollbackAction(for: deploy))
                    // The rolled-back deploy becomes the newest one, so history is now stale.
                    await deploysStore.refresh()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { deploy in
            Text("\(rollbackAction(for: deploy).confirmationMessage)\n\n\(deploy.commitSubject ?? deploy.id)")
        }
    }

    private var serviceName: String { store.service?.name ?? "this service" }

    private func rollbackAction(for deploy: DeploySummary) -> ServiceAction {
        .rollback(deployID: deploy.id)
    }

    private var loadingFooter: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .listRowSeparator(.hidden)
        .onAppear { Task { await deploysStore.loadNextPage() } }
    }

    @ViewBuilder
    private var banner: some View {
        if let result = store.actionResult {
            HStack(spacing: 8) {
                Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(result.message).font(.subheadline)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { store.dismissActionResult() }
                    .labelStyle(.iconOnly)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(result.isFailure ? .red : .green)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = deploysStore.errorMessage, deploysStore.deploys.isEmpty {
            ContentUnavailableView {
                Label("Couldn't load deploys", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await deploysStore.refresh() } }
            }
        } else if deploysStore.deploys.isEmpty && deploysStore.isLoading {
            ProgressView()
        } else if deploysStore.deploys.isEmpty {
            ContentUnavailableView(
                "No Deploys",
                systemImage: "shippingbox",
                description: Text("This service hasn't deployed yet.")
            )
        }
    }
}
