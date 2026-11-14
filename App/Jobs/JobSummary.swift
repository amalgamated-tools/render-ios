import Foundation
import RenderAPI

/// One one-off job: the command it ran, on which plan, and how far it got.
///
/// The spec inlines the job schema separately in each of the four job operations, so the generator
/// emits four unrelated payload types with identical fields. This flattens them into one value so the
/// list, the detail screen and the polling loop all handle the same thing.
struct JobSummary: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable {
        case pending
        case running
        case succeeded
        case failed
        case canceled

        /// Still able to change: worth polling, and worth offering Cancel.
        var isActive: Bool { self == .pending || self == .running }

        var displayName: String {
            switch self {
            case .pending: "Pending"
            case .running: "Running"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .canceled: "Canceled"
            }
        }
    }

    let id: String
    let startCommand: String
    let planID: String
    /// `nil` when Render omits it (the spec marks it optional) or sends a value this build doesn't
    /// know. Treated as settled rather than active, so an unknown state never polls forever.
    let status: Status?
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?

    init(
        id: String,
        startCommand: String,
        planID: String,
        status: String?,
        createdAt: Date,
        startedAt: Date?,
        finishedAt: Date?
    ) {
        self.id = id
        self.startCommand = startCommand
        self.planID = planID
        self.status = status.flatMap(Status.init(rawValue:))
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    var isActive: Bool { status?.isActive ?? false }

    /// How long it ran, once it has both ends. A job canceled while pending never started.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }
}

extension JobSummary {
    init(_ job: Components.Schemas.JobWithCursor.JobPayload) {
        self.init(
            id: job.id, startCommand: job.startCommand, planID: job.planId, status: job.status?.rawValue,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt
        )
    }

    init(_ job: Operations.PostJob.Output.Created.Body.JsonPayload) {
        self.init(
            id: job.id, startCommand: job.startCommand, planID: job.planId, status: job.status?.rawValue,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt
        )
    }

    init(_ job: Operations.RetrieveJob.Output.Ok.Body.JsonPayload) {
        self.init(
            id: job.id, startCommand: job.startCommand, planID: job.planId, status: job.status?.rawValue,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt
        )
    }

    init(_ job: Operations.CancelJob.Output.Ok.Body.JsonPayload) {
        self.init(
            id: job.id, startCommand: job.startCommand, planID: job.planId, status: job.status?.rawValue,
            createdAt: job.createdAt, startedAt: job.startedAt, finishedAt: job.finishedAt
        )
    }
}
