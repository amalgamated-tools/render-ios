import RenderAPI
import SwiftUI

/// The workspace's Blueprints, presented from the account menu. Read-only.
struct BlueprintsView: View {
    @State private var store: BlueprintsStore
    @Environment(\.dismiss) private var dismiss

    private let client: RenderClient
    private let ownerID: String

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: BlueprintsStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        NavigationStack {
            List {
                if store.hasLoaded {
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if store.blueprints.isEmpty, store.errorMessage == nil {
                        ContentUnavailableView(
                            "No Blueprints",
                            systemImage: "doc.text.below.ecg",
                            description: Text("A Blueprint manages this workspace's resources from a render.yaml file in a repo.")
                        )
                    }
                    ForEach(store.blueprints) { blueprint in
                        NavigationLink {
                            BlueprintDetailView(client: client, ownerID: ownerID, blueprint: blueprint)
                        } label: {
                            BlueprintRow(blueprint: blueprint)
                        }
                        // The loading, error and empty rows are cells too; UI tests wait for this one.
                        .accessibilityIdentifier("blueprintRow")
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Blueprints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await store.load() }
            .refreshable { await store.load() }
        }
    }
}

private struct BlueprintRow: View {
    let blueprint: Blueprint

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(blueprint.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
                StatusChip(
                    title: BlueprintDisplay.statusName(blueprint.status),
                    systemImage: BlueprintDisplay.statusImage(blueprint.status),
                    tint: BlueprintDisplay.statusTint(blueprint.status),
                    isCompact: true,
                    isActive: blueprint.status == "syncing"
                )
            }
            Text(BlueprintFormat.repoName(blueprint.repo) + " · " + blueprint.branch)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(BlueprintFormat.lastSyncText(blueprint.lastSync))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

enum BlueprintFormat {
    /// `https://github.com/owner/repo` → `owner/repo`. Anything else comes back unchanged.
    static func repoName(_ repo: String) -> String {
        guard let url = URL(string: repo), let host = url.host(), !host.isEmpty else { return repo }
        let path = url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let name = path.hasSuffix(".git") ? String(path.dropLast(4)) : path
        return name.isEmpty ? repo : name
    }

    /// An https link to the repo, when the repo is one.
    static func repoURL(_ repo: String) -> URL? {
        guard let url = URL(string: repo), url.scheme?.lowercased() == "https", url.host() != nil else { return nil }
        return url
    }

    static func lastSyncText(_ date: Date?) -> String {
        guard let date else { return "Never synced" }
        return "Synced " + date.formatted(.relative(presentation: .named))
    }
}

/// One Blueprint: status, source, the resources it manages, and its recent syncs.
struct BlueprintDetailView: View {
    @State private var store: BlueprintDetailStore

    private let client: RenderClient
    private let ownerID: String
    private let title: String

    init(client: RenderClient, ownerID: String, blueprint: Blueprint) {
        self.client = client
        self.ownerID = ownerID
        self.title = blueprint.name
        _store = State(initialValue: BlueprintDetailStore(client: client, blueprintID: blueprint.id, initial: blueprint))
    }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if let blueprint = store.blueprint {
                overview(blueprint)
            }
            resourcesSection
            syncsSection
        }
        .navigationTitle(store.blueprint?.name ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    @ViewBuilder
    private func overview(_ blueprint: Blueprint) -> some View {
        Section {
            HStack {
                Text("Status")
                Spacer()
                StatusChip(
                    title: BlueprintDisplay.statusName(blueprint.status),
                    systemImage: BlueprintDisplay.statusImage(blueprint.status),
                    tint: BlueprintDisplay.statusTint(blueprint.status),
                    isCompact: true,
                    isActive: blueprint.status == "syncing"
                )
            }
            LabeledContent("Auto-Sync", value: blueprint.autoSync ? "On" : "Off")
            LabeledContent("Last Sync") {
                if let lastSync = blueprint.lastSync {
                    Text(lastSync, format: .relative(presentation: .named))
                } else {
                    Text("Never")
                }
            }
        }
        Section("Source") {
            if let url = BlueprintFormat.repoURL(blueprint.repo) {
                Link(destination: url) {
                    LabeledContent("Repository", value: BlueprintFormat.repoName(blueprint.repo))
                }
            } else {
                LabeledContent("Repository", value: blueprint.repo)
            }
            LabeledContent("Branch", value: blueprint.branch)
            LabeledContent("File", value: blueprint.path)
        }
    }

    @ViewBuilder
    private var resourcesSection: some View {
        Section("Resources") {
            if !store.hasLoaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if store.resources.isEmpty, store.errorMessage == nil {
                Text("This Blueprint doesn't manage any resources.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.resources) { resource in
                    resourceRow(resource)
                }
            }
        }
    }

    @ViewBuilder
    private func resourceRow(_ resource: BlueprintResource) -> some View {
        let label = ResourceLabel(resource: resource)
        switch resource.destination {
        case .service:
            NavigationLink {
                ServiceDetailView(client: client, ownerID: ownerID, serviceID: resource.id, serviceName: resource.name)
            } label: { label }
        case .postgres:
            NavigationLink {
                PostgresDetailView(client: client, ownerID: ownerID, postgresID: resource.id, databaseName: resource.name)
            } label: { label }
        case .keyValue:
            NavigationLink {
                // The Blueprint doesn't carry a dashboard link, so the detail screen goes without one.
                KeyValueDetailView(client: client, ownerID: ownerID, keyValueID: resource.id,
                                   instanceName: resource.name, dashboardURL: nil)
            } label: { label }
        case nil:
            label
        }
    }

    @ViewBuilder
    private var syncsSection: some View {
        Section {
            if let message = store.syncsErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if !store.hasLoadedSyncs {
                ProgressView().frame(maxWidth: .infinity)
            } else if store.syncs.isEmpty, store.syncsErrorMessage == nil {
                Text("No syncs yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.syncs) { sync in
                    SyncRow(sync: sync)
                }
            }
        } header: {
            Text("Recent Syncs")
        }
    }
}

private struct ResourceLabel: View {
    let resource: BlueprintResource

    var body: some View {
        HStack(spacing: 12) {
            GlyphTile(systemImage: BlueprintDisplay.resourceTypeImage(resource.type), tint: .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(resource.name)
                    .lineLimit(1)
                Text(BlueprintDisplay.resourceTypeName(resource.type))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct SyncRow: View {
    let sync: BlueprintSync

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: BlueprintDisplay.syncStateImage(sync.state))
                .foregroundStyle(BlueprintDisplay.syncStateTint(sync.state))
                .symbolEffect(.pulse, isActive: sync.state == "running")
            VStack(alignment: .leading, spacing: 2) {
                Text(BlueprintDisplay.syncStateName(sync.state))
                Text(sync.shortCommit)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let date = sync.completedAt ?? sync.startedAt {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
