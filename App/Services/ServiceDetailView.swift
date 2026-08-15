import RenderAPI
import SwiftUI

/// The service detail screen: a hero header answering what this is, whether it's up, where it runs
/// and how to open it; then the facts worth knowing at 3am; then the drill-downs. Lifecycle actions
/// live in the toolbar menu, each behind a confirmation.
struct ServiceDetailView: View {
    @State private var store: ServiceDetailStore
    /// The action awaiting confirmation. Non-nil drives the confirmation dialog.
    @State private var pendingAction: ServiceAction?
    @State private var isShowingScaleSheet = false
    @State private var watchDenialMessage: String?
    @Environment(FailureWatchCoordinator.self) private var coordinator
    @Environment(NotificationRouter.self) private var router

    private let client: RenderClient
    /// Needed by the log screen: `/logs` is scoped by workspace, and a service ID alone won't do.
    private let ownerID: String
    private let serviceID: String
    private let serviceName: String

    /// - Parameter serviceName: The name already shown in the list, used as the title until the
    ///   detail request lands so the screen doesn't open blank.
    init(client: RenderClient, ownerID: String, serviceID: String, serviceName: String) {
        self.client = client
        self.ownerID = ownerID
        self.serviceID = serviceID
        self.serviceName = serviceName
        _store = State(initialValue: ServiceDetailStore(client: client, serviceID: serviceID))
    }

    var body: some View {
        List {
            if let service = store.service {
                heroHeader(for: service)
                if !service.details.matchesDeclaredType {
                    detailsMismatchWarning
                }
                deploySection
                watchSection
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
        // A failure banner for the service you're already staring at is noise; the delegate reads
        // this to decide whether to present one.
        .onAppear { router.foregroundServiceID = serviceID }
        .onDisappear {
            store.stopPolling()
            if router.foregroundServiceID == serviceID { router.foregroundServiceID = nil }
        }
        .overlay { errorState }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
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

    /// The answers you want before reading anything else: what this is, whether it's up, where it
    /// runs, and how to open it. Previously these were scattered between a section header and four
    /// LabeledContent rows halfway down a wall of them.
    private func heroHeader(for service: ServiceDetailModel) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            HStack(spacing: Theme.Spacing.row) {
                GlyphTile(systemImage: service.type.systemImage, tint: service.type.accent, size: 44)

                VStack(alignment: .leading, spacing: 2) {
                    Text(service.name)
                        .font(.title2.bold())
                        .lineLimit(2)
                    Text(service.type.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if service.isSuspended {
                    suspendedBadge(service)
                }
            }

            deployStatus

            if !factChips.isEmpty {
                // Wraps rather than truncates: on a cron job in a long-named region at largest
                // Dynamic Type these do not fit on one line.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.tight) { chips }
                    VStack(alignment: .leading, spacing: Theme.Spacing.tight) { chips }
                }
            }

            if let url = service.details.url, let parsed = URL(string: url) {
                Link(destination: parsed) {
                    Label(parsed.host() ?? url, systemImage: "arrow.up.right.square")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(.vertical, Theme.Spacing.tight)
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private var deployStatus: some View {
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

    /// Region, instance type, and instance count — the three facts that were LabeledContent rows in
    /// Configuration. They are shown here instead of in both places.
    private var factChips: [(title: String, systemImage: String)] {
        guard let details = store.service?.details else { return [] }
        var chips: [(String, String)] = []
        if let region = details.region {
            chips.append((region.rawValue.capitalized, "globe.americas"))
        }
        if let plan = details.plan {
            chips.append((plan.rawValue.replacingOccurrences(of: "_", with: " ").capitalized, "cpu"))
        }
        if let instances = details.numInstances {
            var title = "\(instances) \(instances == 1 ? "instance" : "instances")"
            if let autoscaling = details.autoscaling, autoscaling.isEnabled {
                title += " · auto \(autoscaling.min)–\(autoscaling.max)"
            }
            chips.append((title, "square.stack.3d.up"))
        }
        return chips
    }

    private var chips: some View {
        ForEach(factChips, id: \.title) { chip in
            FactChip(title: chip.title, systemImage: chip.systemImage)
        }
    }

    /// The commit that shipped, without its status — the hero already says that. Omitted entirely
    /// when there is no deploy, rather than left as a section header over nothing: "Never deployed"
    /// is stated once, in the hero.
    @ViewBuilder
    private var deploySection: some View {
        if let deploy = store.latestDeploy {
            Section("Current Deploy") {
                DeployRow(deploy: deploy, showsStatus: false)
                if deploy.isInProgress {
                    Label("Watching for updates…", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Opting this service into failure notifications.
    ///
    /// The footer says what the feature can and can't promise. An alerting feature that quietly
    /// depends on iOS choosing to wake the app is worse than no feature at all if the user thinks
    /// they've been paged.
    private var watchSection: some View {
        Section {
            Toggle(isOn: watchBinding) {
                Label("Notify Me About Failures", systemImage: "bell")
            }
        } footer: {
            if let watchDenialMessage {
                Text(watchDenialMessage)
                    .foregroundStyle(.orange)
            } else if coordinator.watchlist.isWatching(serviceID) {
                Text("This device checks for failed deploys and failed instances when you open the app, and periodically in the background. iOS decides how often background checks run, so this isn't a pager.")
            } else {
                Text("Get a notification on this device when a deploy or an instance fails.")
            }
        }
    }

    private var watchBinding: Binding<Bool> {
        Binding(
            get: { coordinator.watchlist.isWatching(serviceID) },
            set: { shouldWatch in
                Task {
                    watchDenialMessage = nil
                    guard shouldWatch else {
                        coordinator.unwatch(serviceID: serviceID)
                        return
                    }
                    let name = store.service?.name ?? serviceName
                    guard await coordinator.watch(serviceID: serviceID, ownerID: ownerID, name: name) else {
                        watchDenialMessage = "You can watch up to \(WatchlistStore.limit) services. Stop watching one to add another."
                        return
                    }
                    // Watching without permission would go through the motions and deliver nothing,
                    // which is the worst possible outcome for an alert.
                    if await coordinator.authorization() == .denied {
                        watchDenialMessage = "Notifications are turned off for this app. Turn them on in Settings to be told about failures."
                    }
                }
            }
        )
    }

    @ViewBuilder
    private func configurationSection(for service: ServiceDetailModel) -> some View {
        let details = service.details
        // Instance type, region, and instance count are deliberately absent: they are the fact
        // chips in the hero header, and saying them twice on one screen is how a config list stops
        // being scannable.
        Section("Configuration") {
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
            // The URL is the hero's link button, not a row here.
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
            NavigationLink {
                // A config write saves without deploying, so both screens carry a deployer: the
                // success banner offers Deploy rather than sending the user back here for it.
                EnvVarsView(
                    client: client,
                    serviceID: service.id,
                    deployer: ConfigDeployer.make(client: client, service: service)
                )
            } label: {
                Label("Environment", systemImage: "key")
            }
            NavigationLink {
                SecretFilesView(
                    client: client,
                    serviceID: service.id,
                    deployer: ConfigDeployer.make(client: client, service: service)
                )
            } label: {
                Label("Secret Files", systemImage: "doc.text")
            }
            NavigationLink {
                // The other half of the Environment screen's answer: what this service inherits from
                // a group, which its own variable list deliberately doesn't show.
                ServiceEnvGroupsView(
                    client: client,
                    ownerID: ownerID,
                    service: service,
                    deployer: ConfigDeployer.make(client: client, service: service)
                )
            } label: {
                Label("Env Groups", systemImage: "rectangle.stack")
            }
            // Withheld rather than shown-and-failing: these endpoints answer 406 for a service type
            // that doesn't have them. See `ServiceConfigCatalog`.
            if ServiceConfigCatalog.hasCustomDomains(service.type) {
                NavigationLink {
                    CustomDomainsView(client: client, serviceID: service.id)
                } label: {
                    Label("Custom Domains", systemImage: "globe")
                }
            }
            if ServiceConfigCatalog.hasEdgeRules(service.type) {
                NavigationLink {
                    RouteRulesView(
                        client: client,
                        serviceID: service.id,
                        deployer: ConfigDeployer.make(client: client, service: service)
                    )
                } label: {
                    Label("Redirects & Rewrites", systemImage: "arrow.triangle.branch")
                }
                NavigationLink {
                    HeaderRulesView(
                        client: client,
                        serviceID: service.id,
                        deployer: ConfigDeployer.make(client: client, service: service)
                    )
                } label: {
                    Label("Headers", systemImage: "text.append")
                }
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
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .foregroundStyle(result.isFailure ? .red : .green)
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var errorState: some View {
        if let message = store.errorMessage, store.service == nil {
            ErrorStateView(subject: "service", message: message) { await store.refresh() }
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
