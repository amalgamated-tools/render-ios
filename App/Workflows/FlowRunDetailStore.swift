import Foundation
import Observation
import RenderAPI

/// One flow run: its input, result, error, attempts and steps, and cancelling it. An unfinished run
/// is refreshed every few seconds while the screen is open, so its steps appear as they happen.
@MainActor
@Observable
final class FlowRunDetailStore {
    private(set) var run: FlowRunDetail?
    /// In the order the flow took them.
    private(set) var steps: [FlowRunStep] = []
    /// True when the run has more steps than one page holds; the screen says only the first are shown.
    private(set) var hasMoreSteps = false
    /// The run's flow by name. Nil until looked up, or if the lookup failed; the screen shows the ID.
    private(set) var flowName: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isCanceling = false
    private(set) var actionResult: TaskRunActionResult?

    let runID: String
    private let client: RenderClient
    private let refreshInterval: Duration

    init(client: RenderClient, runID: String, flowName: String? = nil, refreshInterval: Duration = .seconds(3)) {
        self.client = client
        self.runID = runID
        self.flowName = flowName
        self.refreshInterval = refreshInterval
    }

    var canCancel: Bool { run.map { !$0.status.isFinished } ?? false }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let id = runID
            async let detail = client.api.getFlowRun(path: .init(flowRunId: id)).ok.body.json
            async let stepPage = client.api.listFlowRunSteps(path: .init(flowRunId: id), query: .init(limit: 100)).ok.body.json
            let (loaded, page) = try await (detail, stepPage)
            run = FlowRunDetail(loaded)
            steps = page.steps.map(FlowRunStep.init).sorted { ($0.seq, $0.stepKey) < ($1.seq, $1.stepKey) }
            hasMoreSteps = page.hasMore
            if flowName == nil {
                flowName = try? await client.api.getFlow(path: .init(flowId: loaded.flowId)).ok.body.json.name
            }
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// Loads, then keeps refreshing until the run finishes or the screen goes away. A run that never
    /// loaded isn't polled: pull to refresh retries it.
    func watch() async {
        await load()
        while !Task.isCancelled, run.map({ !$0.status.isFinished }) ?? false {
            try? await Task.sleep(for: refreshInterval)
            if Task.isCancelled { break }
            await load()
        }
    }

    /// Cancels the run. Steps it already took stay done.
    func cancel() async {
        guard canCancel, !isCanceling else { return }
        isCanceling = true
        defer { isCanceling = false }
        do {
            _ = try await client.api.cancelFlowRun(path: .init(flowRunId: runID)).noContent
            actionResult = TaskRunActionResult(message: "Run canceled.", isFailure: false)
            await load()
        } catch {
            actionResult = TaskRunActionResult(
                message: "Couldn't cancel: \(RenderError.wrapping(error).errorDescription ?? "unknown error")",
                isFailure: true
            )
        }
    }

    func dismissActionResult() { actionResult = nil }
}

/// One step's input, result and error, fetched when the step is opened.
@MainActor
@Observable
final class FlowRunStepStore {
    private(set) var detail: FlowRunStepDetail?
    private(set) var errorMessage: String?

    let runID: String
    let step: FlowRunStep
    private let client: RenderClient

    init(client: RenderClient, runID: String, step: FlowRunStep) {
        self.client = client
        self.runID = runID
        self.step = step
    }

    func load() async {
        do {
            let loaded = try await client.api.getFlowRunStep(
                path: .init(flowRunId: runID, stepSeq: step.seq),
                // Only a step repeated under one seq has a key. Render accepts "" too, but leaving it
                // out says the same thing more plainly.
                query: .init(stepKey: step.stepKey.isEmpty ? nil : step.stepKey)
            ).ok.body.json
            detail = FlowRunStepDetail(loaded)
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }
}
