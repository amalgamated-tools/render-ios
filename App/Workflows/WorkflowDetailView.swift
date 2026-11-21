import RenderAPI
import SwiftUI

/// One workflow: where its code comes from, the tasks and flows its current version registered, and
/// its versions, newest first.
struct WorkflowDetailView: View {
    @State private var store: WorkflowDetailStore
    private let client: RenderClient

    init(client: RenderClient, workflow: WorkflowSummary) {
        self.client = client
        _store = State(initialValue: WorkflowDetailStore(client: client, workflow: workflow))
    }

    private var workflow: WorkflowSummary { store.workflow }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            detailsSection
            Section {
                NavigationLink {
                    TaskRunsView(client: client, scope: .workflow(id: workflow.id), title: "All Runs")
                } label: {
                    Label("All Runs", systemImage: "list.bullet.rectangle")
                }
            }
            entriesSection("Tasks", entries: store.tasks, empty: "No tasks in this version.")
            entriesSection("Flows", entries: store.flows, empty: "No flows in this version.")
            versionsSection
        }
        .navigationTitle(workflow.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
    }

    private var detailsSection: some View {
        Section {
            LabeledContent("Repository") {
                Text(workflow.repoDisplay)
                    .textSelection(.enabled)
            }
            if let branch = workflow.branch {
                LabeledContent("Branch", value: branch)
            }
            if let rootDir = workflow.rootDir {
                LabeledContent("Root Directory", value: rootDir)
            }
            LabeledContent("Runtime", value: workflow.runtime)
            LabeledContent("Region", value: workflow.region)
            command("Build Command", workflow.buildCommand)
            command("Run Command", workflow.runCommand)
            if let autoDeploy = workflow.autoDeploy {
                LabeledContent("Auto-Deploy", value: Self.autoDeployTitle(autoDeploy))
            }
        }
    }

    private func command(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func entriesSection(_ title: String, entries: [WorkflowEntry], empty: String) -> some View {
        Section {
            ForEach(entries) { entry in
                if title == "Tasks" {
                    // Runs are filtered by slug so every version's runs of this task show up.
                    NavigationLink {
                        TaskRunsView(client: client, scope: .task(slug: "\(workflow.slug)/\(entry.name)"), title: entry.name)
                    } label: {
                        Text(entry.name)
                            .font(.system(.body, design: .monospaced))
                    }
                } else {
                    Text(entry.name)
                        .font(.system(.body, design: .monospaced))
                }
            }
            if store.hasLoaded, entries.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
            } else if !store.hasLoaded, store.errorMessage == nil {
                ProgressView()
            }
        } header: {
            Text(entries.isEmpty ? title : "\(title) (\(entries.count))")
        } footer: {
            if title == "Tasks", let version = store.currentVersion {
                Text("From version \(version.name).")
            }
        }
    }

    private var versionsSection: some View {
        Section("Versions") {
            ForEach(store.versions) { version in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(version.name)
                                .font(.system(.body, design: .monospaced))
                            if version.id == store.currentVersion?.id {
                                MiniBadge(title: "Current", tint: .accentColor)
                            }
                        }
                        Text(version.createdAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VersionStatusChip(status: version.status)
                }
            }
        }
    }

    private static func autoDeployTitle(_ raw: String) -> String {
        switch raw {
        case "commit": "On Commit"
        case "checksPass": "After CI Checks Pass"
        case "off": "Off"
        default: raw
        }
    }
}

private struct VersionStatusChip: View {
    let status: WorkflowVersionSummary.Status

    var body: some View {
        StatusChip(
            title: status.title,
            systemImage: status.isFailure ? "xmark.circle.fill"
                : status.isInProgress ? "hammer.fill" : "checkmark.circle.fill",
            tint: status.isFailure ? .red : status.isInProgress ? .orange : .green,
            isCompact: true,
            isActive: status.isInProgress
        )
    }
}
