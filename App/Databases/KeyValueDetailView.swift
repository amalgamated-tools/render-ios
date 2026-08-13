import RenderAPI
import SwiftUI

/// The Key Value detail screen. Same chrome as ``PostgresDetailView`` with the smaller action set.
struct KeyValueDetailView: View {
    @State private var store: KeyValueDetailStore
    /// The action awaiting confirmation. Non-nil drives the confirmation dialog.
    @State private var pendingAction: KeyValueAction?

    private let client: RenderClient
    /// Needed by the log screen: `/logs` is scoped by workspace, and an instance ID alone won't do.
    private let ownerID: String
    private let instanceName: String
    /// Carried from the list row: the detail schema has no `dashboardUrl` of its own.
    private let dashboardURL: URL?

    /// - Parameter instanceName: The name already shown in the list, used as the title until the
    ///   detail request lands so the screen doesn't open blank.
    init(client: RenderClient, ownerID: String, keyValueID: String, instanceName: String, dashboardURL: URL?) {
        self.client = client
        self.ownerID = ownerID
        self.instanceName = instanceName
        self.dashboardURL = dashboardURL
        _store = State(initialValue: KeyValueDetailStore(client: client, keyValueID: keyValueID))
    }

    var body: some View {
        List {
            if let instance = store.instance {
                statusSection(for: instance)
                configurationSection(for: instance)
                connectionSection
                drillDownSection(for: instance)
                dashboardSection(for: instance)
            } else if store.errorMessage != nil {
                EmptyView()
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(store.instance?.name ?? instanceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { actionsMenu }
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .onDisappear { store.stopPolling() }
        .overlay { errorState }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .confirmationDialog(
            pendingAction?.confirmationTitle(instanceName: store.instance?.name ?? instanceName) ?? "",
            isPresented: .init(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action.title, role: action.isDestructive ? .destructive : nil) {
                Task { await store.perform(action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.confirmationMessage)
        }
    }

    // MARK: - Sections

    private func statusSection(for instance: KeyValueDetailModel) -> some View {
        Section("Status") {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.title2)
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key Value · Valkey \(instance.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DatabaseStatusChip(status: instance.status)
                }
                Spacer()
            }

            if instance.status.isTransitional {
                Label("Watching for updates…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let scheduledAt = instance.maintenanceScheduledAt {
                Label {
                    Text("Maintenance scheduled for \(scheduledAt.formatted(.dateTime))")
                } icon: {
                    Image(systemName: "wrench.and.screwdriver")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    private func configurationSection(for instance: KeyValueDetailModel) -> some View {
        Section("Configuration") {
            LabeledContent("Plan", value: instance.planDisplayName)
            LabeledContent("Region", value: instance.region.rawValue.capitalized)
            LabeledContent("Version", value: "Valkey \(instance.version)")
            if let policy = instance.maxmemoryPolicy {
                LabeledContent("Eviction Policy", value: policy)
                    .monospaced()
            }
            if let mode = instance.persistenceMode {
                LabeledContent("Persistence", value: mode.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if instance.ipAllowListCount > 0 {
                LabeledContent("IP Allow List", value: "\(instance.ipAllowListCount) rule\(instance.ipAllowListCount == 1 ? "" : "s")")
            }
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section("Connection") {
            if let connection = store.connection {
                LabeledContent("Internal URL") {
                    SecretValueView(value: connection.internalConnectionString)
                }
                LabeledContent("External URL") {
                    SecretValueView(value: connection.externalConnectionString)
                }
                LabeledContent("CLI Command") {
                    SecretValueView(value: connection.cliCommand)
                }
            } else if store.connectionErrorMessage != nil {
                Label("Connection info unavailable", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else {
                ProgressView()
            }
        }
    }

    private func drillDownSection(for instance: KeyValueDetailModel) -> some View {
        Section {
            NavigationLink {
                LogsView(client: client, ownerID: ownerID, resourceIDs: [instance.id])
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
            NavigationLink {
                MetricsView(
                    client: client,
                    resourceID: instance.id,
                    charts: MetricsCatalog.charts(forKeyValue: instance)
                )
            } label: {
                Label("Metrics", systemImage: "chart.xyaxis.line")
            }
        }
    }

    @ViewBuilder
    private func dashboardSection(for instance: KeyValueDetailModel) -> some View {
        Section {
            if let url = dashboardURL {
                Link(destination: url) {
                    Label("Open in Render Dashboard", systemImage: "arrow.up.forward.square")
                }
            }
        } footer: {
            Text("Updated \(instance.updatedAt.formatted(.relative(presentation: .named)))")
        }
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var actionsMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ForEach(store.availableActions) { action in
                    Button(action.title, systemImage: action.systemImage, role: action.isDestructive ? .destructive : nil) {
                        pendingAction = action
                    }
                }
            } label: {
                if store.actionInFlight != nil {
                    ProgressView()
                } else {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
            .disabled(store.instance == nil || store.actionInFlight != nil)
        }
    }

    @ViewBuilder
    private var actionBanner: some View {
        if let result = store.actionResult {
            HStack(spacing: 8) {
                Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(result.message)
                    .font(.subheadline)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { store.dismissActionResult() }
                    .labelStyle(.iconOnly)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(result.isFailure ? .red : .green)
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var errorState: some View {
        if let message = store.errorMessage, store.instance == nil {
            ContentUnavailableView {
                Label("Couldn't load instance", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await store.refresh() } }
            }
        }
    }
}
