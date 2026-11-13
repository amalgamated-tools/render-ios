import RenderAPI
import SwiftUI

/// The Postgres detail screen: status up top, then configuration, credentials, and the
/// drill-downs. Lifecycle actions live in the toolbar menu, each behind a confirmation.
struct PostgresDetailView: View {
    @State private var store: PostgresDetailStore
    /// The action awaiting confirmation. Non-nil drives the confirmation dialog.
    @State private var pendingAction: PostgresAction?

    private let client: RenderClient
    /// Needed by the log screen: `/logs` is scoped by workspace, and a database ID alone won't do.
    private let ownerID: String
    private let databaseName: String

    /// - Parameter databaseName: The name already shown in the list, used as the title until the
    ///   detail request lands so the screen doesn't open blank.
    init(client: RenderClient, ownerID: String, postgresID: String, databaseName: String) {
        self.client = client
        self.ownerID = ownerID
        self.databaseName = databaseName
        _store = State(initialValue: PostgresDetailStore(client: client, postgresID: postgresID))
    }

    var body: some View {
        List {
            if let database = store.database {
                statusSection(for: database)
                configurationSection(for: database)
                connectionSection
                drillDownSection(for: database)
                dashboardSection(for: database)
            } else if store.errorMessage != nil {
                EmptyView()
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(store.database?.name ?? databaseName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { actionsMenu }
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .onDisappear { store.stopPolling() }
        .overlay { errorState }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
        .confirmationDialog(
            pendingAction?.confirmationTitle(databaseName: store.database?.name ?? databaseName) ?? "",
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

    private func statusSection(for database: PostgresDetailModel) -> some View {
        Section("Status") {
            HStack(spacing: 12) {
                Image(systemName: "cylinder.split.1x2")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Postgres \(database.version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    DatabaseStatusChip(status: database.status)
                }
                Spacer()
                if database.isSuspended {
                    suspendedBadge(database)
                }
            }

            if database.status.isTransitional {
                Label("Watching for updates…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let scheduledAt = database.maintenanceScheduledAt {
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

    private func configurationSection(for database: PostgresDetailModel) -> some View {
        Section("Configuration") {
            LabeledContent("Plan", value: database.planDisplayName)
            LabeledContent("Region", value: database.region.rawValue.capitalized)
            LabeledContent("Version", value: "Postgres \(database.version)")
            LabeledContent("Database", value: database.databaseName)
            LabeledContent("User", value: database.databaseUser)
            if let diskSizeGB = database.diskSizeGB {
                LabeledContent("Disk") {
                    HStack(spacing: 6) {
                        Text("\(diskSizeGB) GB")
                        if database.isDiskAutoscalingEnabled {
                            Text("autoscaling")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            LabeledContent("High Availability", value: database.isHighAvailabilityEnabled ? "On" : "Off")
            if database.role == .replica {
                LabeledContent("Role", value: "Read replica")
                if let primaryID = database.primaryPostgresID {
                    LabeledContent("Primary", value: primaryID)
                }
            }
            if !database.readReplicaNames.isEmpty {
                LabeledContent("Read Replicas", value: database.readReplicaNames.joined(separator: ", "))
            }
            if database.ipAllowListCount > 0 {
                LabeledContent("IP Allow List", value: "\(database.ipAllowListCount) rule\(database.ipAllowListCount == 1 ? "" : "s")")
            }
            if let expiresAt = database.expiresAt {
                LabeledContent("Expires", value: expiresAt.formatted(.relative(presentation: .named)))
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
                LabeledContent("Password") {
                    SecretValueView(value: connection.password)
                }
                if let poolString = connection.internalConnectionPoolString {
                    LabeledContent("Internal Pool URL") {
                        SecretValueView(value: poolString)
                    }
                }
                if let poolString = connection.externalConnectionPoolString {
                    LabeledContent("External Pool URL") {
                        SecretValueView(value: poolString)
                    }
                }
                LabeledContent("PSQL Command") {
                    SecretValueView(value: connection.psqlCommand)
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

    private func drillDownSection(for database: PostgresDetailModel) -> some View {
        Section {
            NavigationLink {
                LogsView(client: client, ownerID: ownerID, resourceIDs: [database.id])
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
            NavigationLink {
                MetricsView(
                    client: client,
                    resourceID: database.id,
                    charts: MetricsCatalog.charts(forPostgres: database)
                )
            } label: {
                Label("Metrics", systemImage: "chart.xyaxis.line")
            }
            NavigationLink {
                PostgresInsightsView(client: client, postgresID: database.id)
            } label: {
                Label("Query Insights", systemImage: "magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func dashboardSection(for database: PostgresDetailModel) -> some View {
        Section {
            if let url = database.dashboardURL {
                Link(destination: url) {
                    Label("Open in Render Dashboard", systemImage: "arrow.up.forward.square")
                }
            }
        } footer: {
            Text("Updated \(database.updatedAt.formatted(.relative(presentation: .named)))")
        }
    }

    private func suspendedBadge(_ database: PostgresDetailModel) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Suspended")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
            // Who suspended it decides whether resuming is even possible — a billing suspension
            // won't lift from this app.
            if let suspender = database.suspenders.first {
                Text(suspender.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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
            .disabled(store.database == nil || store.actionInFlight != nil)
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
        if let message = store.errorMessage, store.database == nil {
            ErrorStateView(subject: "database", message: message) { await store.refresh() }
        }
    }
}
