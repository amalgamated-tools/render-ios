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
                            ProjectDetailView(client: client, ownerID: ownerID, project: project)
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
    private let client: RenderClient
    private let ownerID: String

    init(client: RenderClient, ownerID: String, project: ProjectSummary) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: ProjectDetailStore(client: client, project: project))
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
                            EnvironmentDetailView(client: client, ownerID: ownerID, environment: environment)
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
        .task { await store.load() }
        .refreshable { await store.load() }
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
    private let client: RenderClient

    init(client: RenderClient, ownerID: String, environment: EnvironmentSummary) {
        self.client = client
        _store = State(initialValue: EnvironmentResourcesStore(client: client, ownerID: ownerID, environment: environment))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Protected", value: store.environment.isProtected ? "Yes" : "No")
                LabeledContent("Network Isolation", value: store.environment.networkIsolationEnabled ? "On" : "Off")
            }
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
        .task { await store.load() }
        .refreshable { await store.load() }
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
                }
            }
        }
    }
}
