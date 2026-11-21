import RenderAPI
import SwiftUI

/// The workspace's workflows. A tab, like env groups, because a workflow belongs to the workspace
/// rather than to any service.
struct WorkflowsListView: View {
    @State private var store: WorkflowsStore
    private let client: RenderClient

    init(client: RenderClient, ownerID: String) {
        self.client = client
        _store = State(initialValue: WorkflowsStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.workflows.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(store.sortedWorkflows) { workflow in
                    NavigationLink {
                        WorkflowDetailView(client: client, workflow: workflow)
                    } label: {
                        row(for: workflow)
                    }
                }
            } footer: {
                if !store.workflows.isEmpty {
                    Text("Workflows belong to the workspace, not to a project.")
                }
            }
        }
        .navigationTitle("Workflows")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
        .overlay { emptyOrErrorState }
    }

    private func row(for workflow: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workflow.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(workflow.repoDisplay)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(workflow.runtime) · \(workflow.region)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.workflows.isEmpty {
            if let message = store.errorMessage {
                ErrorStateView(subject: "workflows", message: message) { await store.load() }
            } else if !store.hasLoaded {
                SkeletonList()
            } else {
                ContentUnavailableView {
                    Label("No Workflows", systemImage: "point.3.filled.connected.trianglepath.dotted")
                } description: {
                    Text("A workflow runs tasks from your own code, on demand.")
                }
            }
        }
    }
}
