import Foundation
import OpenAPIRuntime
import RenderAPI

// Flow runs use the same statuses as task runs, so they share `TaskRunStatus`, its chip and
// `TaskRunFormat`.

/// One run of a flow, as the run list describes it. The list leaves out input, results and attempts.
struct FlowRunSummary: Identifiable, Hashable, Sendable {
    let id: String
    let flowID: String
    let status: TaskRunStatus
    let startedAt: Date?
    let completedAt: Date?

    init(_ run: Components.Schemas.FlowRunWithCursor.FlowRunPayload) {
        id = run.id
        flowID = run.flowId
        status = TaskRunStatus(raw: run.status.rawValue)
        startedAt = run.startedAt
        completedAt = run.completedAt
    }

    var duration: Duration? { TaskRunFormat.duration(from: startedAt, to: completedAt) }

    /// Runs not yet started sort first, since they're the newest.
    nonisolated static func newestFirst(_ a: FlowRunSummary, _ b: FlowRunSummary) -> Bool {
        switch (a.startedAt, b.startedAt) {
        case let (a?, b?): a > b
        case (nil, _?): true
        case (_?, nil): false
        case (nil, nil): a.id > b.id
        }
    }
}

/// One flow run with everything the detail endpoint returns.
struct FlowRunDetail: Hashable, Sendable {
    let id: String
    let flowID: String
    let status: TaskRunStatus
    let startedAt: Date?
    let completedAt: Date?
    /// Pretty-printed JSON.
    let input: String
    /// Pretty-printed JSON, or nil while the flow hasn't returned anything (Render sends `[]`).
    let results: String?
    let error: String?
    let attempts: [FlowRunAttempt]

    init(_ run: Operations.GetFlowRun.Output.Ok.Body.JsonPayload) {
        id = run.id
        flowID = run.flowId
        status = TaskRunStatus(raw: run.status.rawValue)
        startedAt = run.startedAt
        completedAt = run.completedAt
        input = switch run.input {
        case .case1(let values): TaskRunFormat.json(values)
        case .case2(let object): TaskRunFormat.json(object.additionalProperties)
        }
        results = run.results.isEmpty ? nil : TaskRunFormat.results(run.results)
        error = run.error.flatMap { $0.isEmpty ? nil : $0 }
        attempts = run.attempts
            .map {
                FlowRunAttempt(
                    number: $0.attempt + 1,
                    status: TaskRunStatus(raw: $0.status.rawValue),
                    startedAt: $0.startedAt,
                    error: $0.error.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            .sorted { $0.number < $1.number }
    }

    var duration: Duration? { TaskRunFormat.duration(from: startedAt, to: completedAt) }
}

struct FlowRunAttempt: Identifiable, Hashable, Sendable {
    let number: Int
    let status: TaskRunStatus
    let startedAt: Date?
    let error: String?

    var id: Int { number }
}

/// What kind of step a flow took: work done in the flow itself, a task run it started, or a pause.
enum FlowStepKind: String, Sendable {
    case inline, detached, sleep

    init(raw: String) {
        self = Self(rawValue: raw) ?? .inline
    }

    var title: String {
        switch self {
        case .inline: "Step"
        case .detached: "Task Run"
        case .sleep: "Sleep"
        }
    }
}

/// One step of a flow run, as the step list describes it.
struct FlowRunStep: Identifiable, Hashable, Sendable {
    let seq: Int
    let stepKey: String
    let name: String
    let kind: FlowStepKind
    let status: TaskRunStatus
    let startedAt: Date
    let completedAt: Date?
    let wakeAt: Date?
    /// The task run a detached step started.
    let childTaskRunID: String?

    /// A step repeated in a loop shares its seq and differs by key, so both make the identity.
    var id: String { "\(seq)/\(stepKey)" }
    var duration: Duration? { TaskRunFormat.duration(from: startedAt, to: completedAt) }

    init(_ step: Operations.ListFlowRunSteps.Output.Ok.Body.JsonPayload.StepsPayloadPayload) {
        self.init(
            seq: step.seq, stepKey: step.stepKey, name: step.name, kind: step._type.rawValue,
            status: step.status.rawValue, startedAt: step.startedAt, completedAt: step.completedAt,
            wakeAt: step.wakeAt, childTaskRunID: step.childTaskRunId
        )
    }

    /// The same step as its own endpoint reports it, which is newer than the list it was opened from.
    init(_ step: Operations.GetFlowRunStep.Output.Ok.Body.JsonPayload) {
        self.init(
            seq: step.seq, stepKey: step.stepKey, name: step.name, kind: step._type.rawValue,
            status: step.status.rawValue, startedAt: step.startedAt, completedAt: step.completedAt,
            wakeAt: step.wakeAt, childTaskRunID: step.childTaskRunId
        )
    }

    private init(
        seq: Int, stepKey: String, name: String?, kind: String, status: String,
        startedAt: Date, completedAt: Date?, wakeAt: Date?, childTaskRunID: String?
    ) {
        self.seq = seq
        self.stepKey = stepKey
        // A step only lacks a name if the flow didn't give one; its position is the best label then.
        self.name = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Step \(seq + 1)"
        self.kind = FlowStepKind(raw: kind)
        self.status = TaskRunStatus(raw: status)
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.wakeAt = wakeAt
        self.childTaskRunID = childTaskRunID.flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// One step with its input, result and error, which only the step's own endpoint returns.
struct FlowRunStepDetail: Hashable, Sendable {
    let input: String?
    let result: String?
    let error: String?

    init(_ step: Operations.GetFlowRunStep.Output.Ok.Body.JsonPayload) {
        input = step.input.map(TaskRunFormat.json)
        result = step.result.map(TaskRunFormat.json)
        error = step.error.flatMap { $0.isEmpty ? nil : $0 }
    }
}
