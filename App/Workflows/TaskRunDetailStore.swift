import Foundation
import Observation
import RenderAPI

/// One task run: its input, results, error and attempts, the runs it started, and cancelling it.
///
/// An unfinished run is refreshed every few seconds while the screen is open (`watch()`), so a run
/// you just started moves from Pending to Running to its result without pulling to refresh.
@MainActor
@Observable
final class TaskRunDetailStore {
    private(set) var run: TaskRunDetail?
    /// Runs this one started itself, such as `add_squares` running `square` twice.
    private(set) var children: [TaskRunSummary] = []
    /// The run's task by name. Nil until looked up, or if the lookup failed; the screen shows the ID.
    private(set) var taskName: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isCanceling = false
    private(set) var actionResult: TaskRunActionResult?

    let runID: String
    private let client: RenderClient
    private let refreshInterval: Duration

    init(client: RenderClient, runID: String, refreshInterval: Duration = .seconds(3)) {
        self.client = client
        self.runID = runID
        self.refreshInterval = refreshInterval
    }

    var canCancel: Bool { run.map { !$0.status.isFinished } ?? false }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let id = runID
        let loaded: Operations.GetTaskRun.Output.Ok.Body.JsonPayload
        do {
            loaded = try await client.api.getTaskRun(path: .init(taskRunId: id)).ok.body.json
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            return
        }
        run = TaskRunDetail(loaded)
        errorMessage = nil
        if taskName == nil {
            taskName = try? await client.api.getTask(path: .init(taskId: loaded.taskId)).ok.body.json.name
        }
        // Children share the run's root, which is this run's own ID only when it is the root. Listing
        // by root gets the whole family in one request; this run's direct children say so in
        // parentTaskRunId. Best-effort: if the list fails, the run still shows, with the children
        // from the last load.
        let root = loaded.rootTaskRunId.isEmpty ? id : loaded.rootTaskRunId
        if let related = try? await client.api
            .listTaskRuns(query: .init(limit: 100, rootTaskRunId: [root])).ok.body.json {
            children = related.map { TaskRunSummary($0.taskRun) }
                .filter { $0.parentID == id }
                .sorted(by: TaskRunsStore.newestFirst)
        }
    }

    /// Loads, then keeps refreshing until the run finishes or the calling task is cancelled (the
    /// screen goes away). A failed refresh of a loaded run doesn't stop it; the next one may work.
    /// A run that never loaded isn't polled: pull to refresh retries it.
    func watch() async {
        await load()
        while !Task.isCancelled, run.map({ !$0.status.isFinished }) ?? false {
            try? await Task.sleep(for: refreshInterval)
            if Task.isCancelled { break }
            await load()
        }
    }

    /// Cancels the run. Render stops it where it is; anything it already did stays done.
    func cancel() async {
        guard canCancel, !isCanceling else { return }
        isCanceling = true
        defer { isCanceling = false }
        do {
            _ = try await client.api.cancelTaskRun(path: .init(taskRunId: runID)).noContent
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

struct TaskRunActionResult: ActionOutcome, Equatable {
    let id = UUID()
    let message: String
    let isFailure: Bool
}
