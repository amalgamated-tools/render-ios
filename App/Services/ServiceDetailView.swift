import RenderAPI
import SwiftUI

/// The service detail screen: current deploy status up top, then the facts worth knowing at 3am,
/// then the drill-downs. Lifecycle actions live in the toolbar menu, each behind a confirmation.
struct ServiceDetailView: View {
    @State private var store: ServiceDetailStore
    /// The action awaiting confirmation. Non-nil drives the confirmation dialog.
    @State private var pendingAction: ServiceAction?
    @State private var isShowingScaleSheet = false

    private let client: RenderClient
    /// Needed by the log screen: `/logs` is scoped by workspace, and a service ID alone won't do.
    private let ownerID: String
    private let serviceName: String

    /// - Parameter serviceName: The name already shown in the list, used as the title until the
    ///   detail request lands so the screen doesn't open blank.
    init(client: RenderClient, ownerID: String, serviceID: String, serviceName: String) {
        self.client = client
        self.ownerID = ownerID
        self.serviceName = serviceName
        _store = State(initialValue: ServiceDetailStore(client: client, serviceID: serviceID))
    }

    var body: some View {
        List {
            if let service = store.service {
                if !service.details.matchesDeclaredType {
                    detailsMismatchWarning
                }
                deploySection(for: service)
                configurationSection(for: service)
                drillDownSection(for: service)
                dashboardSection(for: service)
            } else if store.errorMessage != nil {
                EmptyView()
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(store.service?.name ?? serviceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { actionsMenu }
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .onDisappear { store.stopPolling() }
        .overlay { errorState }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .confirmationDialog(
            pendingAction?.confirmationTitle(serviceName: store.service?.name ?? serviceName) ?? "",
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
        .sheet(isPresented: $isShowingScaleSheet) {
            if let service = store.service {
                // Self-contained rather than routed through `pendingAction`: presenting a
                // confirmation dialog in the same turn a sheet dismisses drops the dialog.
                ScaleSheet(
                    serviceName: service.name,
                    currentInstances: service.details.numInstances ?? 1,
                    isAutoscalingEnabled: service.details.autoscaling?.isEnabled ?? false
                ) { instances in
                    Task { await store.perform(.scale(instances: instances)) }
                }
            }
        }
    }

    // MARK: - Sections

    private func deploySection(for service: ServiceDetailModel) -> some View {
        Section("Current Deploy") {
            HStack(spacing: 12) {
                Image(systemName: service.type.systemImage)
                    .font(.title2)
                    .foregroundStyle(service.type.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(service.type.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let status = store.latestDeploy?.status {
                        DeployStatusChip(status: status)
                    } else if store.deployErrorMessage != nil {
                        Text("Deploy status unavailable")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.orange)
                    } else if store.latestDeploy == nil {
                        Text("Never deployed")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if service.isSuspended {
                    suspendedBadge(service)
                }
            }

            if let deploy = store.latestDeploy {
                DeployRow(deploy: deploy, showsStatus: false)
                if deploy.isInProgress {
                    Label("Watching for updates…", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func configurationSection(for service: ServiceDetailModel) -> some View {
        let details = service.details
        Section("Configuration") {
            if let plan = details.plan {
                LabeledContent("Instance Type", value: plan.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if let region = details.region {
                LabeledContent("Region", value: region.rawValue.capitalized)
            }
            if let instances = details.numInstances {
                LabeledContent("Instances") {
                    HStack(spacing: 6) {
                        Text("\(instances)")
                        if let autoscaling = details.autoscaling, autoscaling.isEnabled {
                            Text("auto \(autoscaling.min)–\(autoscaling.max)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let schedule = details.schedule {
                LabeledContent("Schedule", value: schedule)
                    .monospaced()
            }
            if let lastRun = details.lastSuccessfulRunAt {
                LabeledContent("Last Success", value: lastRun.formatted(.relative(presentation: .named)))
            }
            if let runtime = details.runtime {
                LabeledContent("Runtime", value: runtime.rawValue.capitalized)
            }
            if let repo = service.repo {
                LabeledContent("Repository", value: shortRepo(repo))
            }
            if let branch = service.branch {
                LabeledContent("Branch", value: branch)
            }
            if let imagePath = service.imagePath {
                LabeledContent("Image", value: imagePath)
            }
            LabeledContent("Auto-Deploy", value: service.isAutoDeployEnabled ? "On" : "Off")
            if let healthCheckPath = details.healthCheckPath, !healthCheckPath.isEmpty {
                LabeledContent("Health Check", value: healthCheckPath)
            }
            if let disk = details.disk {
                LabeledContent("Disk", value: "\(disk.name) · \(disk.sizeGB) GB · \(disk.mountPath)")
            }
            if details.isMaintenanceModeEnabled {
                Label("Maintenance mode is on", systemImage: "wrench.and.screwdriver.fill")
                    .foregroundStyle(.orange)
            }
            if let url = details.url, let parsed = URL(string: url) {
                Link(destination: parsed) {
                    LabeledContent("URL", value: parsed.host() ?? url)
                }
            }
        }
    }

    private func drillDownSection(for service: ServiceDetailModel) -> some View {
        Section {
            NavigationLink {
                // Handed the same store so a rollback confirms — and reports — on the screen the
                // user is actually looking at.
                DeploysListView(client: client, store: store)
            } label: {
                Label("Deploys", systemImage: "shippingbox")
            }
            NavigationLink {
                LogsView(client: client, ownerID: ownerID, resourceIDs: [service.id])
            } label: {
                Label("Logs", systemImage: "text.alignleft")
            }
            NavigationLink {
                // Which charts exist depends on the service — a static site has no CPU — so the
                // catalog is resolved from the loaded service rather than fixed by the screen.
                MetricsView(
                    client: client,
                    resourceID: service.id,
                    charts: MetricsCatalog.charts(for: service)
                )
            } label: {
                Label("Metrics", systemImage: "chart.xyaxis.line")
            }
            NavigationLink {
                ServiceEventsView(client: client, serviceID: service.id)
            } label: {
                Label("Events", systemImage: "list.bullet.rectangle")
            }
        }
    }

    @ViewBuilder
    private func dashboardSection(for service: ServiceDetailModel) -> some View {
        Section {
            if let url = service.dashboardURL {
                Link(destination: url) {
                    Label("Open in Render Dashboard", systemImage: "arrow.up.forward.square")
                }
            }
        } footer: {
            Text("Updated \(service.updatedAt.formatted(.relative(presentation: .named)))")
        }
    }

    private func suspendedBadge(_ service: ServiceDetailModel) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("Suspended")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .foregroundStyle(.orange)
            // Who suspended it decides whether resuming is even possible — a billing suspension
            // won't lift from this app.
            if let suspender = service.suspenders.first {
                Text(suspender.rawValue.replacingOccurrences(of: "_", with: " "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Shown when the `serviceDetails` union decoded as a different type than `service.type` says.
    /// The fields below it may be missing or wrong, so say so rather than presenting them as fact.
    private var detailsMismatchWarning: some View {
        Label {
            Text("Some configuration below may be incomplete — Render returned details in an unexpected shape for this service type.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.footnote)
        .foregroundStyle(.orange)
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
                if let service = store.service, service.type.supportsScaling {
                    Button("Scale…", systemImage: "arrow.up.arrow.down") {
                        isShowingScaleSheet = true
                    }
                }
            } label: {
                if store.actionInFlight != nil {
                    ProgressView()
                } else {
                    Label("Actions", systemImage: "ellipsis.circle")
                }
            }
            .disabled(store.service == nil || store.actionInFlight != nil)
        }
    }

    /// Action outcomes land in a bottom inset rather than an alert: the user is often firing two
    /// actions in a row, and a modal between them is friction for no safety gain (the confirmation
    /// already happened).
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
        if let message = store.errorMessage, store.service == nil {
            ContentUnavailableView {
                Label("Couldn't load service", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await store.refresh() } }
            }
        }
    }

    /// `https://github.com/acme/api` → `acme/api`.
    private func shortRepo(_ repo: String) -> String {
        guard let url = URL(string: repo) else { return repo }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.isEmpty ? repo : parts.suffix(2).joined(separator: "/")
    }
}

/// Instance-count picker. Separate from the confirmation dialog because scaling needs a *value*
/// first; confirming happens after, through the same dialog as every other action.
private struct ScaleSheet: View {
    let serviceName: String
    let currentInstances: Int
    let isAutoscalingEnabled: Bool
    let onSubmit: @MainActor (Int) -> Void

    @State private var instances: Int
    @Environment(\.dismiss) private var dismiss

    init(
        serviceName: String,
        currentInstances: Int,
        isAutoscalingEnabled: Bool,
        onSubmit: @escaping @MainActor (Int) -> Void
    ) {
        self.serviceName = serviceName
        self.currentInstances = currentInstances
        self.isAutoscalingEnabled = isAutoscalingEnabled
        self.onSubmit = onSubmit
        _instances = State(initialValue: currentInstances)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Render's own manual-scaling ceiling; the API would reject more.
                    Stepper("Instances: \(instances)", value: $instances, in: 1...100)
                } footer: {
                    if isAutoscalingEnabled {
                        Text("Autoscaling is enabled for \(serviceName), so Render will ignore a manual instance count.")
                    } else {
                        Text("Currently running \(currentInstances).")
                    }
                }
            }
            .navigationTitle("Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Scale") {
                        dismiss()
                        onSubmit(instances)
                    }
                    .disabled(instances == currentInstances)
                }
            }
        }
    }
}
