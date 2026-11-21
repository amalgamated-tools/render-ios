import RenderAPI
import SwiftUI

/// Recent runs of one flow, or of every flow in a workflow. For a flow, also offers **Run Flow…**.
struct FlowRunsView: View {
    @State private var store: FlowRunsStore
    @State private var isStarting = false
    @State private var startedRunID: String?
    private let client: RenderClient
    private let title: String

    init(client: RenderClient, scope: FlowRunsStore.Scope, title: String) {
        self.client = client
        self.title = title
        _store = State(initialValue: FlowRunsStore(client: client, scope: scope))
    }

    private var isOneFlow: Bool {
        if case .flow = store.scope { true } else { false }
    }

    /// A flow's own list knows the flow's name; a workflow-wide list looks it up per run.
    private func flowName(_ run: FlowRunSummary) -> String {
        isOneFlow ? title : (store.flowNames[run.flowID] ?? run.flowID)
    }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(store.runs) { run in
                    NavigationLink {
                        FlowRunDetailView(client: client, runID: run.id, flowName: flowName(run))
                    } label: {
                        FlowRunRow(run: run, flowName: isOneFlow ? nil : flowName(run))
                    }
                }
                if store.hasLoaded, store.runs.isEmpty {
                    Text("No runs yet.")
                        .foregroundStyle(.secondary)
                } else if !store.hasLoaded, store.errorMessage == nil {
                    ProgressView()
                }
            } footer: {
                if store.hasLoaded, !store.runs.isEmpty {
                    Text("The most recent runs, newest first.")
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isOneFlow {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run Flow…", systemImage: "play.fill") { isStarting = true }
                        .accessibilityIdentifier("runFlow")
                }
            }
        }
        .sheet(isPresented: $isStarting) {
            StartRunSheet(store: store, name: title) { id in
                startedRunID = id
            }
        }
        .navigationDestination(item: $startedRunID) { id in
            FlowRunDetailView(client: client, runID: id, flowName: title)
        }
        .refreshable { await store.load() }
        .task {
            await store.load()
            while !Task.isCancelled, store.hasUnfinishedRuns {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await store.load()
            }
        }
    }
}

struct FlowRunRow: View {
    let run: FlowRunSummary
    /// Shown in a workflow-wide list. A flow's own list leaves it out, since it's the title.
    var flowName: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                details
                Spacer(minLength: 8)
                TaskRunStatusChip(status: run.status)
            }
            VStack(alignment: .leading, spacing: 6) {
                details
                TaskRunStatusChip(status: run.status)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let started = run.startedAt {
                Text(started, format: .relative(presentation: .named))
            } else {
                Text("Not started")
            }
            if let duration = run.duration {
                Text(duration, format: .units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let flowName {
                Text(flowName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
