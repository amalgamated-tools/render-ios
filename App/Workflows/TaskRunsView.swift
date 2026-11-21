import RenderAPI
import SwiftUI

/// Recent runs of one task, or of every task in a workflow. For a task, also offers **Run Task…**.
struct TaskRunsView: View {
    @State private var store: TaskRunsStore
    @State private var isStarting = false
    @State private var startedRunID: String?
    private let client: RenderClient
    private let title: String

    init(client: RenderClient, scope: TaskRunsStore.Scope, title: String) {
        self.client = client
        self.title = title
        _store = State(initialValue: TaskRunsStore(client: client, scope: scope))
    }

    private var canStart: Bool {
        if case .task = store.scope { true } else { false }
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
                        TaskRunDetailView(client: client, runID: run.id)
                    } label: {
                        TaskRunRow(run: run, taskName: canStart ? nil : (store.taskNames[run.taskID] ?? run.taskID))
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
            if canStart {
                ToolbarItem(placement: .primaryAction) {
                    Button("Run Task…", systemImage: "play.fill") { isStarting = true }
                        .accessibilityIdentifier("runTask")
                }
            }
        }
        .sheet(isPresented: $isStarting) {
            StartRunSheet(store: store, name: title) { id in
                startedRunID = id
            }
        }
        .navigationDestination(item: $startedRunID) { id in
            TaskRunDetailView(client: client, runID: id)
        }
        .refreshable { await store.load() }
        .task {
            await store.load()
            // Keep a list with pending or running runs moving while it's on screen.
            while !Task.isCancelled, store.hasUnfinishedRuns {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { break }
                await store.load()
            }
        }
    }
}

struct TaskRunRow: View {
    let run: TaskRunSummary
    /// Shown in a workflow-wide list, where which task ran matters. A task's own list leaves it
    /// out, since it's the title.
    var taskName: String?

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
            HStack(spacing: 6) {
                if let duration = run.duration {
                    Text(duration, format: .units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2))
                }
                if run.attemptCount > 1 {
                    Text("\(run.attemptCount) attempts")
                }
                if run.parentID != nil {
                    Text("Started by another run")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let taskName {
                Text(taskName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct TaskRunStatusChip: View {
    let status: TaskRunStatus

    var body: some View {
        StatusChip(
            title: status.title,
            systemImage: status.systemImage,
            tint: status.tint,
            isCompact: true,
            isActive: status == .running || status == .pending
        )
    }
}

/// A store that can start a run from typed JSON input: a task's runs or a flow's runs.
@MainActor
protocol RunStarting: AnyObject, Observable {
    var isStarting: Bool { get }
    var startError: String? { get }
    func start(inputText: String) async -> String?
    func clearStartError()
}

extension TaskRunsStore: RunStarting {}
extension FlowRunsStore: RunStarting {}

/// Typing a task's or flow's input and starting it.
struct StartRunSheet<Store: RunStarting>: View {
    let store: Store
    let name: String
    let started: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var input = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("[ ]", text: $input, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(3...10)
                        .accessibilityIdentifier("taskInput")
                } header: {
                    Text("Input")
                } footer: {
                    Text("A JSON array of arguments, like [7], or an object of named arguments. Leave blank for none.")
                }
                if let error = store.startError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Run \(name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isStarting {
                        ProgressView()
                    } else {
                        Button("Run") {
                            Task {
                                if let id = await store.start(inputText: input) {
                                    dismiss()
                                    started(id)
                                }
                            }
                        }
                        .accessibilityIdentifier("startRun")
                    }
                }
            }
            .onAppear { store.clearStartError() }
        }
    }
}
