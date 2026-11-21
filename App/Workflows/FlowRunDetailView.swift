import RenderAPI
import SwiftUI

/// One flow run: status, timing, input, result or error, retries, and its steps in order. Each step
/// opens to its own input and result. An unfinished run can be cancelled, behind a confirmation.
struct FlowRunDetailView: View {
    @State private var store: FlowRunDetailStore
    @State private var isConfirmingCancel = false
    private let client: RenderClient

    init(client: RenderClient, runID: String, flowName: String? = nil) {
        self.client = client
        _store = State(initialValue: FlowRunDetailStore(client: client, runID: runID, flowName: flowName))
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
                stepsSection
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
            } else if store.errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle("Flow Run")
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
            Text("Render stops the flow where it is. Steps it already took stay done.")
        }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
        .refreshable { await store.load() }
        .task { await store.watch() }
    }

    private func summary(_ run: FlowRunDetail) -> some View {
        Section {
            HStack {
                Text("Status")
                Spacer(minLength: 8)
                TaskRunStatusChip(status: run.status)
            }
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            LabeledContent("Flow") {
                Text(store.flowName ?? run.flowID)
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
            LabeledContent("Run ID") {
                Text(run.id)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
    }

    private var stepsSection: some View {
        Section {
            ForEach(store.steps) { step in
                NavigationLink {
                    FlowRunStepView(client: client, runID: store.runID, step: step)
                } label: {
                    FlowStepRow(step: step)
                }
            }
            if store.steps.isEmpty {
                Text(store.run?.status.isFinished == true ? "No steps were taken." : "No steps yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(store.steps.isEmpty ? "Steps" : "Steps (\(store.steps.count))")
        } footer: {
            if store.hasMoreSteps {
                Text("Showing the first \(store.steps.count) steps.")
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
    private func attempts(_ run: FlowRunDetail) -> some View {
        // One attempt says nothing the summary didn't.
        if run.attempts.count > 1 {
            Section("Attempts (\(run.attempts.count))") {
                ForEach(run.attempts) { attempt in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Attempt \(attempt.number)")
                            Spacer(minLength: 8)
                            TaskRunStatusChip(status: attempt.status)
                        }
                        if let started = attempt.startedAt {
                            Text(started, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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

struct FlowStepRow: View {
    let step: FlowRunStep

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                details
                Spacer(minLength: 8)
                TaskRunStatusChip(status: step.status)
            }
            VStack(alignment: .leading, spacing: 6) {
                details
                TaskRunStatusChip(status: step.status)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(step.name)
                .font(.system(.body, design: .monospaced))
            HStack(spacing: 6) {
                if step.kind != .inline {
                    Text(step.kind.title)
                }
                if let duration = step.duration {
                    Text(duration, format: .units(allowed: [.minutes, .seconds, .milliseconds], width: .narrow, maximumUnitCount: 2))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// One step: when it ran, its input, its result or error, and the task run it started, if any.
struct FlowRunStepView: View {
    @State private var store: FlowRunStepStore
    private let client: RenderClient

    init(client: RenderClient, runID: String, step: FlowRunStep) {
        self.client = client
        _store = State(initialValue: FlowRunStepStore(client: client, runID: runID, step: step))
    }

    private var step: FlowRunStep { store.step }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                HStack {
                    Text("Status")
                    Spacer(minLength: 8)
                    TaskRunStatusChip(status: step.status)
                }
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                LabeledContent("Kind", value: step.kind.title)
                LabeledContent("Position", value: "\(step.seq + 1)")
                if !step.stepKey.isEmpty {
                    LabeledContent("Key") {
                        Text(step.stepKey)
                            .font(.system(.body, design: .monospaced))
                    }
                }
                LabeledContent("Started") {
                    Text(step.startedAt, format: .dateTime.month().day().hour().minute().second())
                }
                if let completed = step.completedAt {
                    LabeledContent("Finished") {
                        Text(completed, format: .dateTime.month().day().hour().minute().second())
                    }
                }
                if let wake = step.wakeAt {
                    LabeledContent("Wakes") {
                        Text(wake, format: .dateTime.month().day().hour().minute().second())
                    }
                }
                if let duration = step.duration {
                    LabeledContent("Duration") {
                        Text(duration, format: .units(allowed: [.hours, .minutes, .seconds, .milliseconds], width: .abbreviated, maximumUnitCount: 2))
                    }
                }
                if let child = step.childTaskRunID {
                    NavigationLink {
                        TaskRunDetailView(client: client, runID: child)
                    } label: {
                        LabeledContent("Task Run") {
                            Text(child)
                                .font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
            if let detail = store.detail {
                if let input = detail.input {
                    jsonSection("Input", input)
                }
                if let error = detail.error {
                    Section("Error") {
                        Text(error)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                if let result = detail.result {
                    jsonSection("Result", result)
                }
            } else if store.errorMessage == nil {
                ProgressView()
            }
        }
        .navigationTitle(step.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
    }

    private func jsonSection(_ title: String, _ json: String) -> some View {
        Section(title) {
            Text(json)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
