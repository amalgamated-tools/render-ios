import RenderAPI
import SwiftUI

/// The workspace's projects, presented from the account menu. Uses the scope picker's
/// `ProjectsStore`, so both show the same list.
struct ProjectsView: View {
    @Bindable var store: ProjectsStore
    @Environment(\.dismiss) private var dismiss

    let client: RenderClient
    let ownerID: String

    var body: some View {
        NavigationStack {
            List {
                if store.hasLoaded {
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if store.projects.isEmpty, store.errorMessage == nil {
                        ContentUnavailableView(
                            "No Projects",
                            systemImage: "folder",
                            description: Text("Projects group a workspace's services, databases and env groups into environments.")
                        )
                    }
                    ForEach(store.projects) { project in
                        NavigationLink {
                            ProjectDetailView(client: client, ownerID: ownerID, project: project) {
                                store.replace($0)
                            }
                        } label: {
                            LabeledContent {
                                Text(environmentCount(project))
                            } label: {
                                Label(project.name, systemImage: "folder")
                            }
                        }
                        .accessibilityIdentifier("projectRow")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Projects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { if !store.hasLoaded { await store.load() } }
            .refreshable { await store.load() }
        }
    }

    private func environmentCount(_ project: ProjectSummary) -> String {
        project.environmentIDs.count == 1 ? "1 environment" : "\(project.environmentIDs.count) environments"
    }
}

/// One project's environments.
struct ProjectDetailView: View {
    @State private var store: ProjectDetailStore
    @State private var isRenaming = false
    @State private var draftName = ""
    private let client: RenderClient
    private let ownerID: String

    init(client: RenderClient, ownerID: String, project: ProjectSummary,
         onProjectChange: @escaping (ProjectSummary) -> Void = { _ in }) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: ProjectDetailStore(client: client, project: project, onProjectChange: onProjectChange))
    }

    var body: some View {
        List {
            if store.hasLoaded {
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if store.environments.isEmpty, store.errorMessage == nil {
                    ContentUnavailableView("No Environments", systemImage: "square.stack.3d.up")
                }
                Section("Environments") {
                    ForEach(store.environments) { environment in
                        NavigationLink {
                            EnvironmentDetailView(
                                client: client, ownerID: ownerID, environment: environment,
                                destinations: store.destinations(from: environment),
                                onEnvironmentChange: { store.replace($0) },
                                onResourcesChange: { Task { await store.load() } }
                            )
                        } label: {
                            EnvironmentRow(environment: environment)
                        }
                        .accessibilityIdentifier("environmentRow")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(store.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename Project", systemImage: "pencil") {
                    draftName = store.project.name
                    isRenaming = true
                }
                .disabled(store.isSaving)
            }
        }
        .renameAlert("Rename Project", isPresented: $isRenaming, name: $draftName) {
            Task { await store.rename(to: draftName) }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .safeAreaInset(edge: .bottom) {
            if let result = store.actionResult {
                ProjectActionBanner(result: result) { store.dismissActionResult() }
            }
        }
        .actionOutcomeFeedback(store.actionResult)
    }
}

private struct EnvironmentRow: View {
    let environment: EnvironmentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(environment.name).font(.body)
                if environment.isProtected {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Protected")
                }
            }
            Text(EnvironmentDisplay.counts(environment))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum EnvironmentDisplay {
    static func counts(_ environment: EnvironmentSummary) -> String {
        [
            plural(environment.serviceCount, "service", "services"),
            plural(environment.databaseCount, "database", "databases"),
            plural(environment.envGroupCount, "env group", "env groups"),
        ].joined(separator: " · ")
    }

    static func plural(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }
}

/// One environment: its settings and the resources in it. Each resource opens its own screen.
struct EnvironmentDetailView: View {
    @State private var store: EnvironmentResourcesStore
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var isConfirmingUnprotect = false
    @State private var pendingRemoval: ResourceRef?
    private let client: RenderClient
    /// The project's other environments, which a resource here can move to.
    private let destinations: [EnvironmentSummary]

    init(
        client: RenderClient,
        ownerID: String,
        environment: EnvironmentSummary,
        destinations: [EnvironmentSummary] = [],
        onEnvironmentChange: @escaping (EnvironmentSummary) -> Void = { _ in },
        onResourcesChange: @escaping () -> Void = {}
    ) {
        self.client = client
        self.destinations = destinations
        _store = State(initialValue: EnvironmentResourcesStore(
            client: client, ownerID: ownerID, environment: environment,
            onEnvironmentChange: onEnvironmentChange, onResourcesChange: onResourcesChange
        ))
    }

    /// A resource a row's menu acts on.
    struct ResourceRef: Identifiable, Equatable {
        let id: String
        let name: String
    }

    var body: some View {
        List {
            Section {
                Toggle("Protected", isOn: Binding(
                    get: { store.environment.isProtected },
                    set: { isOn in
                        // Turning protection off is the risky direction, so it's confirmed.
                        if isOn { Task { await store.setProtected(true) } } else { isConfirmingUnprotect = true }
                    }
                ))
                Toggle("Network Isolation", isOn: Binding(
                    get: { store.environment.networkIsolationEnabled },
                    set: { isOn in Task { await store.setNetworkIsolation(isOn) } }
                ))
            } footer: {
                Text("Protected environments limit who can change or delete their resources. Network isolation blocks private network traffic from other environments.")
            }
            .disabled(store.isSaving)
            if store.hasLoaded {
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if store.isEmpty, store.errorMessage == nil {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "square.dashed",
                                           description: Text("This environment has no services, databases or env groups."))
                }
                resourceSections
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(store.environment.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Rename Environment", systemImage: "pencil") {
                    draftName = store.environment.name
                    isRenaming = true
                }
                .disabled(store.isSaving)
            }
        }
        .renameAlert("Rename Environment", isPresented: $isRenaming, name: $draftName) {
            Task { await store.rename(to: draftName) }
        }
        .confirmationDialog(
            "Stop protecting \(store.environment.name)?",
            isPresented: $isConfirmingUnprotect,
            titleVisibility: .visible
        ) {
            Button("Remove Protection", role: .destructive) {
                Task { await store.setProtected(false) }
            }
        } message: {
            Text("Anyone with access to the workspace will be able to change or delete its resources.")
        }
        .confirmationDialog(
            "Remove \(pendingRemoval?.name ?? "resource") from \(store.environment.name)?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { resource in
            Button("Remove from Environment", role: .destructive) {
                Task { await store.remove(resourceID: resource.id, name: resource.name) }
            }
        } message: { _ in
            Text("It stays in the workspace, outside any project. Nothing is deleted.")
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .safeAreaInset(edge: .bottom) {
            if let result = store.actionResult {
                ProjectActionBanner(result: result) { store.dismissActionResult() }
            }
        }
        .actionOutcomeFeedback(store.actionResult)
    }

    /// Move and remove, on a row's long-press menu.
    @ViewBuilder private func resourceMenu(id: String, name: String) -> some View {
        if !destinations.isEmpty {
            Menu("Move to", systemImage: "arrow.right.square") {
                ForEach(destinations) { target in
                    Button(target.name) {
                        Task { await store.move(resourceID: id, name: name, to: target) }
                    }
                }
            }
        }
        Button("Remove from Environment", systemImage: "minus.circle", role: .destructive) {
            pendingRemoval = ResourceRef(id: id, name: name)
        }
    }

    @ViewBuilder private var resourceSections: some View {
        let ownerID = store.ownerID
        if !store.services.isEmpty {
            Section("Services") {
                ForEach(store.services) { service in
                    NavigationLink {
                        ServiceDetailView(client: client, ownerID: ownerID, serviceID: service.id, serviceName: service.name)
                    } label: {
                        LabeledContent {
                            Text(service.isSuspended ? "Suspended" : service.type.displayName)
                        } label: {
                            Label(service.name, systemImage: service.type.systemImage)
                        }
                    }
                    .contextMenu { resourceMenu(id: service.id, name: service.name) }
                    .disabled(store.isSaving)
                }
            }
        }
        if !store.postgres.isEmpty || !store.keyValues.isEmpty {
            Section("Databases") {
                ForEach(store.postgres) { database in
                    NavigationLink {
                        PostgresDetailView(client: client, ownerID: ownerID, postgresID: database.id, databaseName: database.name)
                    } label: {
                        LabeledContent {
                            Text("Postgres")
                        } label: {
                            Label(database.name, systemImage: "cylinder.split.1x2")
                        }
                    }
                    .contextMenu { resourceMenu(id: database.id, name: database.name) }
                    .disabled(store.isSaving)
                }
                ForEach(store.keyValues) { instance in
                    NavigationLink {
                        KeyValueDetailView(client: client, ownerID: ownerID, keyValueID: instance.id,
                                           instanceName: instance.name, dashboardURL: instance.dashboardURL)
                    } label: {
                        LabeledContent {
                            Text("Key Value")
                        } label: {
                            Label(instance.name, systemImage: "bolt.horizontal")
                        }
                    }
                    .contextMenu { resourceMenu(id: instance.id, name: instance.name) }
                    .disabled(store.isSaving)
                }
            }
        }
        if !store.envGroups.isEmpty {
            Section("Env Groups") {
                ForEach(store.envGroups) { group in
                    NavigationLink {
                        EnvGroupDetailView(client: client, group: group, ownerID: ownerID)
                    } label: {
                        Label(group.name, systemImage: "list.bullet.rectangle")
                    }
                    .contextMenu { resourceMenu(id: group.id, name: group.name) }
                    .disabled(store.isSaving)
                }
            }
        }
    }
}

/// The outcome of the last write on the project screens.
private struct ProjectActionBanner: View {
    let result: ProjectActionResult
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(result.message)
                .font(.subheadline)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(result.isFailure ? .red : .green)
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private extension View {
    /// An alert with a name field, for renaming.
    func renameAlert(_ title: String, isPresented: Binding<Bool>, name: Binding<String>, save: @escaping () -> Void) -> some View {
        alert(title, isPresented: isPresented) {
            TextField("Name", text: name)
            Button("Cancel", role: .cancel) {}
            Button("Save", action: save)
        }
    }
}
