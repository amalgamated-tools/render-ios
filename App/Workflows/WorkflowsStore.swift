import Foundation
import Observation
import RenderAPI

/// A workflow: a repo of task code that Render builds into versions and runs on demand.
struct WorkflowSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// What a task run is addressed by: `slug/task-name`. Optional in the spec, so it falls back to
    /// the name, which is what Render derives the slug from.
    let slug: String
    let repo: String
    let branch: String?
    let rootDir: String?
    let runtime: String
    let buildCommand: String
    let runCommand: String
    let region: String
    /// The version Render runs tasks against when a run doesn't name one.
    let defaultVersionID: String?
    let autoDeploy: String?
    let updatedAt: Date

    init(_ payload: Components.Schemas.WorkflowWithCursor.WorkflowPayload) {
        id = payload.id
        name = payload.name
        slug = payload.slug.flatMap { $0.isEmpty ? nil : $0 } ?? payload.name
        repo = payload.buildConfig.repo
        branch = payload.buildConfig.branch.flatMap { $0.isEmpty ? nil : $0 }
        rootDir = payload.buildConfig.rootDir.flatMap { $0.isEmpty ? nil : $0 }
        runtime = payload.buildConfig.runtime.rawValue.capitalized
        buildCommand = payload.buildConfig.buildCommand
        runCommand = payload.runCommand
        region = payload.region.rawValue.capitalized
        defaultVersionID = payload.defaultVersionId.flatMap { $0.isEmpty ? nil : $0 }
        autoDeploy = payload.autoDeployTrigger?.rawValue
        updatedAt = payload.updatedAt
    }

    /// The repo without its scheme, which is all a phone-width row has room for.
    var repoDisplay: String {
        repo.replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }
}

/// Lists the workspace's workflows.
///
/// Workspace-wide rather than scoped to the active project, like env groups: a workflow can carry an
/// `environmentId`, but most don't, and filtering would hide every workflow that has none.
@MainActor
@Observable
final class WorkflowsStore {
    private(set) var workflows: [WorkflowSummary] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    private let client: RenderClient
    private let ownerID: String
    private let pageSize: Int

    init(client: RenderClient, ownerID: String, pageSize: Int = 100) {
        self.client = client
        self.ownerID = ownerID
        self.pageSize = pageSize
    }

    var sortedWorkflows: [WorkflowSummary] {
        workflows.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Drains every page: a workspace has a handful of workflows, not hundreds.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            workflows = try await makePaginator().collect()
            errorMessage = nil
            hasLoaded = true
        } catch {
            // Keep what's on screen: "no workflows" and "couldn't ask" are different answers.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.WorkflowWithCursor, WorkflowSummary> {
        let client = client
        let ownerID = ownerID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listWorkflows(query: .init(ownerId: [ownerID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            (WorkflowSummary(envelope.workflow), envelope.cursor)
        }
    }
}
