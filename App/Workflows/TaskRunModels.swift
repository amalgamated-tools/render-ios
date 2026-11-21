import Foundation
import OpenAPIRuntime
import RenderAPI
import SwiftUI

/// Where a task run is. Every run payload in the API spells these the same way but declares its own
/// enum, so they're mapped by raw value.
enum TaskRunStatus: String, Sendable, CaseIterable {
    case pending, running, completed, succeeded, failed, canceled, paused, suspended, sleeping

    init(raw: String) {
        self = Self(rawValue: raw) ?? .pending
    }

    var title: String {
        switch self {
        case .pending: "Pending"
        case .running: "Running"
        case .completed: "Completed"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .canceled: "Canceled"
        case .paused: "Paused"
        case .suspended: "Suspended"
        case .sleeping: "Sleeping"
        }
    }

    /// Done for good: nothing more will happen to the run, so there's nothing to cancel or watch.
    var isFinished: Bool { self == .completed || self == .succeeded || self == .failed || self == .canceled }
    var isFailure: Bool { self == .failed }

    var systemImage: String {
        switch self {
        case .completed, .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .canceled: "minus.circle.fill"
        case .pending: "clock.fill"
        case .running: "play.circle.fill"
        case .paused, .suspended: "pause.circle.fill"
        case .sleeping: "moon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .completed, .succeeded: .green
        case .failed: .red
        case .canceled: .secondary
        case .pending, .paused, .suspended, .sleeping: .orange
        case .running: .blue
        }
    }
}

/// One run of a task, as the run list describes it. The list leaves out input and results.
struct TaskRunSummary: Identifiable, Hashable, Sendable {
    let id: String
    let taskID: String
    let status: TaskRunStatus
    let startedAt: Date?
    let completedAt: Date?
    let parentID: String?
    let rootID: String
    let attemptCount: Int

    init(_ run: Components.Schemas.TaskRunWithCursor.TaskRunPayload) {
        id = run.id
        taskID = run.taskId
        status = TaskRunStatus(raw: run.status.rawValue)
        startedAt = run.startedAt
        completedAt = run.completedAt
        // A root run's parent comes back as "" rather than being left out.
        parentID = run.parentTaskRunId.isEmpty ? nil : run.parentTaskRunId
        rootID = run.rootTaskRunId
        attemptCount = run.attempts.count
    }

    var duration: Duration? { TaskRunFormat.duration(from: startedAt, to: completedAt) }
}

/// One try at a run. A task retries a failed attempt up to its retry limit.
struct TaskRunAttempt: Identifiable, Hashable, Sendable {
    let number: Int
    let status: TaskRunStatus
    let startedAt: Date
    let completedAt: Date?
    let error: String?

    var id: Int { number }
    var duration: Duration? { TaskRunFormat.duration(from: startedAt, to: completedAt) }
}

/// One run with everything the detail endpoint returns: its input, its results and every attempt.
struct TaskRunDetail: Hashable, Sendable {
    let id: String
    let taskID: String
    let status: TaskRunStatus
    let startedAt: Date?
    let completedAt: Date?
    let parentID: String?
    let rootID: String
    let retries: Int
    /// Pretty-printed JSON.
    let input: String
    /// Pretty-printed JSON, or nil when the run hasn't returned anything (Render sends `null`).
    let results: String?
    let error: String?
    let attempts: [TaskRunAttempt]

    init(_ run: Operations.GetTaskRun.Output.Ok.Body.JsonPayload) {
        id = run.id
        taskID = run.taskId
        status = TaskRunStatus(raw: run.status.rawValue)
        startedAt = run.startedAt
        completedAt = run.completedAt
        parentID = run.parentTaskRunId.isEmpty ? nil : run.parentTaskRunId
        rootID = run.rootTaskRunId
        retries = run.retries
        input = switch run.input {
        case .case1(let values): TaskRunFormat.json(values)
        case .case2(let object): TaskRunFormat.json(object.additionalProperties)
        }
        results = run.results.map(TaskRunFormat.results)
        error = run.error.flatMap { $0.isEmpty ? nil : $0 }
        attempts = run.attempts
            .map {
                TaskRunAttempt(
                    number: $0.attempt + 1,
                    status: TaskRunStatus(raw: $0.status.rawValue),
                    startedAt: $0.startedAt,
                    completedAt: $0.completedAt,
                    error: $0.error.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            .sorted { $0.number < $1.number }
    }

    var duration: Duration? { TaskRunFormat.duration(from: startedAt, to: completedAt) }
}

enum TaskRunFormat {
    static func duration(from start: Date?, to end: Date?) -> Duration? {
        guard let start, let end, end >= start else { return nil }
        return .milliseconds(Int64(end.timeIntervalSince(start) * 1000))
    }

    /// A task returns one value, which Render wraps in a one-element array. Show the value itself.
    static func results(_ values: [OpenAPIValueContainer]) -> String {
        values.count == 1 ? json(values[0]) : json(values)
    }

    static func json(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "—"
        }
        return text
    }
}
