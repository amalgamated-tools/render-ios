import RenderAPI
import SwiftUI

/// One task run: status, timing, input, result or error, attempts, and the runs it started.
/// An unfinished run can be cancelled, behind a confirmation.
struct TaskRunDetailView: View {
    @State private var store: TaskRunDetailStore
    @State private var isConfirmingCancel = false
    private let client: RenderClient

    init(client: RenderClient, runID: String) {
        self.client = client
        _store = State(initialValue: TaskRunDetailStore(client: client, runID: runID))
    }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let run = store.run {
                summary(run)
                jsonSection("Input", run.input)
                if let error = run.error {
                    Section("Error") {
                        Text(error)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                if let results = run.results {
                    jsonSection("Result", results)
                }
                attempts(run)
                childRuns
            } else if store.errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle("Task Run")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.canCancel {
                ToolbarItem(placement: .primaryAction) {
                    if store.isCanceling {
                        ProgressView()
                    } else {
                        Button("Cancel Run", systemImage: "stop.circle") { isConfirmingCancel = true }
                            .accessibilityIdentifier("cancelRun")
                    }
                }
            }
        }
        .confirmationDialog(
            "Cancel this run?",
            isPresented: $isConfirmingCancel,
            titleVisibility: .visible
        ) {
            Button("Cancel Run", role: .destructive) {
                Task { await store.cancel() }
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("Render stops the run where it is. Anything it already did stays done.")
        }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
        .refreshable { await store.load() }
        .task { await store.watch() }
    }

    private func summary(_ run: TaskRunDetail) -> some View {
        Section {
            // A plain row: LabeledContent left a tall blank gap under a chip.
            HStack {
                Text("Status")
                Spacer(minLength: 8)
                TaskRunStatusChip(status: run.status)
            }
            // Otherwise the separator starts at the chip's label rather than at the row's.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            LabeledContent("Task") {
                Text(store.taskName ?? run.taskID)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
            if let started = run.startedAt {
                LabeledContent("Started") {
                    Text(started, format: .dateTime.month().day().hour().minute().second())
                }
            }
            if let completed = run.completedAt {
                LabeledContent("Finished") {
                    Text(completed, format: .dateTime.month().day().hour().minute().second())
                }
            }
            if let duration = run.duration {
                LabeledContent("Duration") {
                    Text(duration, format: .units(allowed: [.hours, .minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2))
                }
            }
            if let parent = run.parentID {
                NavigationLink {
                    TaskRunDetailView(client: client, runID: parent)
                } label: {
                    LabeledContent("Started By") {
                        Text(parent)
                            .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
            LabeledContent("Run ID") {
                Text(run.id)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private func jsonSection(_ title: String, _ json: String) -> some View {
        Section(title) {
            Text(json)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func attempts(_ run: TaskRunDetail) -> some View {
        // One attempt says nothing the summary didn't. Retries are worth seeing one by one.
        if run.attempts.count > 1 {
            Section("Attempts (\(run.attempts.count))") {
                ForEach(run.attempts) { attempt in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Attempt \(attempt.number)")
                            Spacer(minLength: 8)
                            TaskRunStatusChip(status: attempt.status)
                        }
                        Text(attempt.startedAt, format: .relative(presentation: .named))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = attempt.error {
                            Text(error)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.red)
                                .lineLimit(4)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var childRuns: some View {
        if !store.children.isEmpty {
            Section("Runs It Started (\(store.children.count))") {
                ForEach(store.children) { child in
                    NavigationLink {
                        TaskRunDetailView(client: client, runID: child.id)
                    } label: {
                        TaskRunRow(run: child, taskName: child.taskID)
                    }
                }
            }
        }
    }

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
}
