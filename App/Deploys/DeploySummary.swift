import Foundation
import RenderAPI

/// A deploy as the UI needs it. Domain projection of `Components.Schemas.Deploy`.
///
/// Almost every field in the generated type is optional — including `status` — so this keeps the
/// optionality rather than inventing defaults, and the views decide what "unknown status" looks like.
struct DeploySummary: Identifiable, Hashable, Sendable {
    let id: String
    let status: Components.Schemas.DeployStatus?
    let trigger: Components.Schemas.Deploy.TriggerPayload?
    let commitID: String?
    let commitMessage: String?
    let commitCreatedAt: Date?
    /// Set for image-backed deploys; `nil` for Git-backed ones.
    let imageRef: String?
    let startedAt: Date?
    let finishedAt: Date?
    let createdAt: Date?

    init(_ deploy: Components.Schemas.Deploy) {
        self.id = deploy.id
        self.status = deploy.status
        self.trigger = deploy.trigger
        self.commitID = deploy.commit?.id
        self.commitMessage = deploy.commit?.message
        self.commitCreatedAt = deploy.commit?.createdAt
        self.imageRef = deploy.image?.ref
        self.startedAt = deploy.startedAt
        self.finishedAt = deploy.finishedAt
        self.createdAt = deploy.createdAt
    }

    /// The most meaningful timestamp available, newest concept first.
    var timestamp: Date? { finishedAt ?? startedAt ?? createdAt }

    /// Wall-clock time the deploy took, once it has finished.
    var duration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    var shortCommitID: String? {
        commitID.map { String($0.prefix(7)) }
    }

    /// First line only — commit messages carry bodies that would wreck a list row.
    var commitSubject: String? {
        commitMessage?
            .split(separator: "\n", maxSplits: 1)
            .first
            .map(String.init)
    }

    var isInProgress: Bool { status?.isInProgress ?? false }

    /// Rollback targets have to be deploys that actually shipped.
    var isRollbackCandidate: Bool { status == .live || status == .deactivated }
}
