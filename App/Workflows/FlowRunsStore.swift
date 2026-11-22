import Foundation
import Observation
import RenderAPI

/// Recent runs of one flow, or of every flow in a workflow, newest first, and starting a new run.
///
/// Like task runs, a flow is filtered by slug: the bare `workflow-slug/flow-name`, which matches only
/// the latest version's runs, plus `workflow-slug/flow-name:version-name` for each known version (see
/// `TaskRunsStore`). A workflow is filtered by its ID. Only the newest page is loaded.
@MainActor
@Observable
final class FlowRunsStore {
    enum Scope: Sendable, Equatable {
        case workflow(id: String)
        /// `versions` are version names, newest first; older runs than these aren't listed.
        case flow(slug: String, versions: [String] = [])
    }

    private(set) var runs: [FlowRunSummary] = []
    /// Flow names by ID, for a workflow-wide list. Empty when the lookup failed; rows show the ID.
    private(set) var flowNames: [String: String] = [:]
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isStarting = false
    private(set) var startError: String?

    let scope: Scope
    private let client: RenderClient
    private let limit: Int
    /// The key of the last start that failed, and the input it was for.
    private var unconfirmedStart: (input: String, key: String)?

    init(client: RenderClient, scope: Scope, limit: Int = 25) {
        self.client = client
        self.scope = scope
        self.limit = limit
    }

    var hasUnfinishedRuns: Bool { runs.contains { !$0.status.isFinished } }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let query: Operations.ListFlowRuns.Input.Query = switch scope {
        case .workflow(let id): .init(limit: limit, workflowId: [id])
        case .flow(let slug, let versions):
            .init(limit: limit, flowSlug: TaskRunsStore.taskSlugs(slug: slug, versions: versions))
        }
        do {
            async let names = flowNamesIfNeeded()
            let page = try await client.api.listFlowRuns(query: query).ok.body.json
            runs = page.map { FlowRunSummary($0.flowRun) }.sorted(by: FlowRunSummary.newestFirst)
            if let loaded = await names { flowNames = loaded }
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// Each version registers its own copy of each flow, so one page covers recent versions' IDs.
    private func flowNamesIfNeeded() async -> [String: String]? {
        guard case .workflow(let id) = scope, flowNames.isEmpty else { return nil }
        guard let flows = try? await client.api.listFlows(query: .init(workflowId: [id], limit: 100)).ok.body.json else {
            return nil
        }
        return Dictionary(flows.map { ($0.flow.id, $0.flow.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Starts a run of this flow with the typed input and returns the new run's ID, or nil when it
    /// couldn't start (with `startError` saying why).
    ///
    /// **Idempotency.** As with task runs, a failed start may still have reached Render, so its key
    /// is kept: trying the same input again reuses it and Render won't start a second run. A
    /// success, or different input, gets a new key.
    func start(inputText: String) async -> String? {
        guard case .flow(let slug, _) = scope, !isStarting else { return nil }
        let input: Operations.StartFlowRun.Input.Body.JsonPayload.InputPayload
        do {
            input = try TaskRunsStore.parseInput(inputText, empty: .case1([]))
        } catch {
            startError = error.errorDescription
            return nil
        }

        let key = unconfirmedStart.flatMap { $0.input == inputText ? $0.key : nil } ?? UUID().uuidString
        unconfirmedStart = (inputText, key)

        isStarting = true
        defer { isStarting = false }
        do {
            let run = try await client.api.startFlowRun(body: .json(.init(
                flow: slug, input: input, idempotencyKey: key
            ))).accepted.body.json
            unconfirmedStart = nil
            startError = nil
            await load()
            return run.id
        } catch {
            startError = RenderError.wrapping(error).errorDescription
            return nil
        }
    }

    func clearStartError() { startError = nil }
}
