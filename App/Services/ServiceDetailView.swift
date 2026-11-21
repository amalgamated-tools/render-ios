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
    @State private var isShowingAutoscalingSheet = false
    @State private var watchDenialMessage: String?
    @Environment(FailureWatchCoordinator.self) private var coordinator
    @Environment(NotificationRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                cronRunSection
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
        .sheet(isPresented: $isShowingAutoscalingSheet) {
            if let service = store.service {
                AutoscalingSheet(
                    serviceName: service.name,
                    saved: service.details.autoscaling,
                    currentInstances: service.details.numInstances ?? 1
                ) { action in
                    Task { await store.perform(action) }
                }
            }
        }
    }

    // MARK: - Sections

    /// The answers you want before reading anything else: what this is, whether it's up, and how to
    /// open it. Region, plan, and instance count were pills here once, but unlabeled pills don't say
    /// what "Starter" is, and at large Dynamic Type they stacked into a table without labels — so
    /// they are the first rows of Configuration instead.
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

            // Only public services get the button. A private service's URL is an internal address
            // like http://internal:10000 that can't open outside Render's private network.
            if service.type == .webService || service.type == .staticSite,
               let url = service.details.url, let parsed = URL(string: url) {
                Link(destination: parsed) {
                    // At accessibility sizes a hostname doesn't fit, and every way of squeezing it
                    // is unreadable: wrapped it breaks into "doc-most-va.onren-der.com", truncated
                    // it's "docmo…", and minimumScaleFactor is ignored inside this bordered button.
                    // So say what the button does instead, and drop the icon, which at the largest
                    // sizes squeezes even that into "Ope-n Webs…"; alone it wraps between words.
                    if dynamicTypeSize.isAccessibilitySize {
                        Text("Open Website")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(parsed.host() ?? url, systemImage: "arrow.up.right.square")
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                    }
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

    /// For a cron job: the run in progress, or how the last one ended. Hidden when neither is known,
    /// so a cron job that has never run doesn't get a section with nothing in it.
    @ViewBuilder
    private var cronRunSection: some View {
        if let run = store.activeCronRun {
            Section("Cron Run") {
                LabeledContent(store.isCancelingCronRun ? "Canceling…" : "Running") {
                    if let startedAt = run.startedAt {
                        Text("since \(startedAt.formatted(date: .omitted, time: .shortened))")
                    } else {
                        Text("Starting…")
                    }
                }
                Label("Watching for updates…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let last = store.lastCronRun {
            Section("Cron Run") {
                LabeledContent("Last Run") {
                    Text("\(last.statusTitle) \(last.endedAt.formatted(.relative(presentation: .named)))")
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
            NavigationLink {
                ServiceNotificationOverridesView(
                    client: client,
                    ownerID: ownerID,
                    serviceID: serviceID,
                    serviceName: store.service?.name ?? serviceName
                )
            } label: {
                Label("Render Notifications", systemImage: "envelope.badge")
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
                    watchDenialMessage = await coordinator
                        .watch(serviceID: serviceID, ownerID: ownerID, name: name)
                        .message
                }
            }
        )
    }

    @ViewBuilder
    private func configurationSection(for service: ServiceDetailModel) -> some View {
        let details = service.details
        // Plan, region, and instance count lead: they are the facts people look for first, and the
        // same labels the Postgres and Key Value screens use.
        Section("Configuration") {
            if let plan = details.plan {
                LabeledContent("Plan", value: plan.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            }
            if let region = details.region {
                LabeledContent("Region", value: region.rawValue.capitalized)
            }
            if let instances = details.numInstances {
                if let autoscaling = details.autoscaling, autoscaling.isEnabled {
                    LabeledContent("Instances", value: "\(instances) · autoscaling \(autoscaling.min)–\(autoscaling.max)")
                } else {
                    LabeledContent("Instances", value: "\(instances)")
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
                    charts: MetricsCatalog.charts(for: service),
                    offersFilters: true
                )
            } label: {
                Label("Metrics", systemImage: "chart.xyaxis.line")
            }
            NavigationLink {
                ServiceEventsView(client: client, serviceID: service.id)
            } label: {
                Label("Events", systemImage: "list.bullet.rectangle")
            }
            if service.type.supportsJobs {
                NavigationLink {
                    JobsListView(
                        client: client,
                        serviceID: service.id,
                        serviceName: service.name,
                        startUnavailableReason: JobsStore.startUnavailableReason(plan: service.details.plan)
                    )
                } label: {
                    Label("Jobs", systemImage: "terminal")
                }
            }
            // Withheld for static sites: they're served from Render's CDN, with no instances of
            // their own and no outbound traffic. See `ServiceConfigCatalog`.
            if ServiceConfigCatalog.hasInstancesAndOutboundIPs(service.type) {
                NavigationLink {
                    ServiceNetworkView(client: client, serviceID: service.id)
                } label: {
                    Label("Instances & IPs", systemImage: "network")
                }
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
                    Button("Autoscaling…", systemImage: "gauge.with.dots.needle.67percent") {
                        isShowingAutoscalingSheet = true
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

/// Edits a service's autoscaling settings, or removes them. Like `ScaleSheet`, Save submits directly:
/// the sheet already shows exactly what will be sent, and a dialog presented as a sheet dismisses
/// gets dropped. Remove confirms inside the sheet, because it deletes settings the user can't get
/// back without retyping them.
private struct AutoscalingSheet: View {
    let serviceName: String
    let saved: ServiceDetails.Autoscaling?
    let onSubmit: @MainActor (ServiceAction) -> Void

    @State private var settings: AutoscalingSettings
    @State private var isConfirmingRemove = false
    @Environment(\.dismiss) private var dismiss

    private let original: AutoscalingSettings

    init(
        serviceName: String,
        saved: ServiceDetails.Autoscaling?,
        currentInstances: Int,
        onSubmit: @escaping @MainActor (ServiceAction) -> Void
    ) {
        self.serviceName = serviceName
        self.saved = saved
        self.onSubmit = onSubmit
        let initial = AutoscalingSettings(saved, currentInstances: currentInstances)
        original = initial
        _settings = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Autoscaling", isOn: $settings.isEnabled)
                } footer: {
                    if !settings.isEnabled {
                        Text("Render keeps these settings but runs a fixed instance count.")
                    }
                }

                Section("Instances") {
                    Stepper("Minimum: \(settings.min)", value: $settings.min, in: AutoscalingSettings.instanceRange)
                    Stepper("Maximum: \(settings.max)", value: $settings.max, in: AutoscalingSettings.instanceRange)
                }

                Section {
                    Toggle("CPU", isOn: $settings.isCPUTargetEnabled)
                    if settings.isCPUTargetEnabled {
                        Stepper(
                            "Target: \(settings.cpuPercent)%",
                            value: $settings.cpuPercent,
                            in: AutoscalingSettings.targetRange
                        )
                    }
                    Toggle("Memory", isOn: $settings.isMemoryTargetEnabled)
                    if settings.isMemoryTargetEnabled {
                        Stepper(
                            "Target: \(settings.memoryPercent)%",
                            value: $settings.memoryPercent,
                            in: AutoscalingSettings.targetRange
                        )
                    }
                } header: {
                    Text("Targets")
                } footer: {
                    if let message = settings.validationMessage {
                        Text(message).foregroundStyle(.red)
                    } else {
                        Text("Render adds instances when average use goes above a target and removes them when it falls below.")
                    }
                }

                if saved != nil {
                    Section {
                        Button("Remove Autoscaling", role: .destructive) {
                            isConfirmingRemove = true
                        }
                    }
                }
            }
            .navigationTitle("Autoscaling")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                        onSubmit(.setAutoscaling(settings))
                    }
                    // A service with no settings yet can save the defaults as they are.
                    .disabled(settings.validationMessage != nil || (saved != nil && settings == original))
                }
            }
            .confirmationDialog(
                ServiceAction.removeAutoscaling.confirmationTitle(serviceName: serviceName),
                isPresented: $isConfirmingRemove,
                titleVisibility: .visible
            ) {
                Button(ServiceAction.removeAutoscaling.title, role: .destructive) {
                    dismiss()
                    onSubmit(.removeAutoscaling)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ServiceAction.removeAutoscaling.confirmationMessage)
            }
        }
    }
}
