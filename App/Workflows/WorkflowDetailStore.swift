import Foundation
import Observation
import RenderAPI

/// One build of a workflow's repo, named after the commit it was built from.
struct WorkflowVersionSummary: Identifiable, Hashable, Sendable {
    enum Status: String, Sendable {
        case created, building, registering, buildFailed, registrationFailed, ready

        var title: String {
            switch self {
            case .created: "Created"
            case .building: "Building"
            case .registering: "Registering"
            case .buildFailed: "Build Failed"
            case .registrationFailed: "Registration Failed"
            case .ready: "Ready"
            }
        }

        var isInProgress: Bool { self == .created || self == .building || self == .registering }
        var isFailure: Bool { self == .buildFailed || self == .registrationFailed }
    }

    let id: String
    let name: String
    let status: Status
    let createdAt: Date

    init(_ payload: Components.Schemas.WorkflowVersionWithCursor.WorkflowVersionPayload) {
        id = payload.id
        name = payload.name
        createdAt = payload.createdAt
        status = switch payload.status {
        case .created: .created
        case .building: .building
        case .registering: .registering
        case .buildFailed: .buildFailed
        case .registrationFailed: .registrationFailed
        case .ready: .ready
        }
    }
}

/// A task or a flow a workflow version registered. The two share a shape in the API and on screen.
struct WorkflowEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let versionID: String?
}

/// A workflow's versions, and the tasks and flows of the version that currently runs.
///
/// **Which version's tasks.** `GET /tasks?workflowId=` answers with the tasks of *every* version,
/// so a workflow built ten times lists each task ten times. The screen shows the default version's —
/// the one a run uses when it doesn't name one — and falls back to the newest ready version when the
/// workflow doesn't say. Versions that are still building or failed registered nothing runnable.
@MainActor
@Observable
final class WorkflowDetailStore {
    private(set) var versions: [WorkflowVersionSummary] = []
    private(set) var tasks: [WorkflowEntry] = []
    private(set) var flows: [WorkflowEntry] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    let workflow: WorkflowSummary
    private let client: RenderClient
    private let pageSize: Int

    init(client: RenderClient, workflow: WorkflowSummary, pageSize: Int = 100) {
        self.client = client
        self.workflow = workflow
        self.pageSize = pageSize
    }

    /// The version whose tasks and flows are shown.
    var currentVersion: WorkflowVersionSummary? {
        if let id = workflow.defaultVersionID, let version = versions.first(where: { $0.id == id }) {
            return version
        }
        return versions.first { $0.status == .ready }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let loadedVersions = fetchVersions()
            async let loadedTasks = fetchTasks()
            async let loadedFlows = fetchFlows()
            let (allVersions, allTasks, allFlows) = try await (loadedVersions, loadedTasks, loadedFlows)

            versions = allVersions.sorted { $0.createdAt > $1.createdAt }
            let versionID = currentVersion?.id
            tasks = Self.entries(allTasks, in: versionID)
            flows = Self.entries(allFlows, in: versionID)
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// The entries of one version, by name. With no version known there's nothing to pick by, so
    /// duplicates are collapsed by name instead of being shown once per build.
    private static func entries(_ all: [WorkflowEntry], in versionID: String?) -> [WorkflowEntry] {
        let chosen: [WorkflowEntry]
        if let versionID {
            chosen = all.filter { $0.versionID == versionID }
        } else {
            var seen = Set<String>()
            chosen = all.filter { seen.insert($0.name).inserted }
        }
        return chosen.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Fetching

    private func fetchVersions() async throws -> [WorkflowVersionSummary] {
        let client = client
        let workflowID = workflow.id
        return try await CursorPaginator<Components.Schemas.WorkflowVersionWithCursor, WorkflowVersionSummary>(
            pageSize: pageSize
        ) { cursor, limit in
            try await client.api
                .listWorkflowVersions(query: .init(workflowID: [workflowID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            (WorkflowVersionSummary(envelope.workflowVersion), envelope.cursor)
        }.collect()
    }

    private func fetchTasks() async throws -> [WorkflowEntry] {
        let client = client
        let workflowID = workflow.id
        return try await CursorPaginator<Components.Schemas.TaskWithCursor, WorkflowEntry>(
            pageSize: pageSize
        ) { cursor, limit in
            try await client.api
                .listTasks(query: .init(workflowId: [workflowID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            let task = envelope.task
            return (WorkflowEntry(id: task.id, name: task.name, versionID: task.workflowVersionId), envelope.cursor)
        }.collect()
    }

    private func fetchFlows() async throws -> [WorkflowEntry] {
        let client = client
        let workflowID = workflow.id
        return try await CursorPaginator<Components.Schemas.FlowWithCursor, WorkflowEntry>(
            pageSize: pageSize
        ) { cursor, limit in
            try await client.api
                .listFlows(query: .init(workflowId: [workflowID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            let flow = envelope.flow
            return (WorkflowEntry(id: flow.id, name: flow.name, versionID: flow.workflowVersionId), envelope.cursor)
        }.collect()
    }
}
