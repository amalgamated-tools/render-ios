import Foundation
import Observation
import RenderAPI

/// One task run: its input, results, error and attempts, the runs it started, and cancelling it.
///
/// While the screen is open, an unfinished run is watched (`watch()`): Render's event stream says the
/// moment it finishes, and polling keeps Pending → Running current, since the stream only reports
/// finished runs. Polling slows down while the stream is connected and speeds back up if it fails.
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
    private let streamingRefreshInterval: Duration
    /// Whether the event stream is connected, which is when polling can slow down.
    private(set) var isStreaming = false

    init(
        client: RenderClient,
        runID: String,
        refreshInterval: Duration = .seconds(3),
        streamingRefreshInterval: Duration = .seconds(15)
    ) {
        self.client = client
        self.runID = runID
        self.refreshInterval = refreshInterval
        self.streamingRefreshInterval = streamingRefreshInterval
    }

    private var isUnfinished: Bool { run.map { !$0.status.isFinished } ?? false }

    var canCancel: Bool { run.map { !$0.status.isFinished } ?? false }

    /// The most family members read per load, so a runaway fan-out can't page forever.
    static let familyLimit = 1000

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
        // by root gets the whole family; this run's direct children say so in parentTaskRunId. The
        // family is paged through before filtering, since a big fan-out spans several pages; it
        // stops at `familyLimit` runs. Best-effort: if the list fails, the run still shows, with the
        // children from the last load.
        let root = loaded.rootTaskRunId.isEmpty ? id : loaded.rootTaskRunId
        let api = client.api
        let family = CursorPaginator(pageSize: 100) { cursor, limit in
            try await api.listTaskRuns(query: .init(cursor: cursor, limit: limit, rootTaskRunId: [root])).ok.body.json
        } unwrap: { (element: Components.Schemas.TaskRunWithCursor) in
            (TaskRunSummary(element.taskRun), element.cursor)
        }
        if let related = try? await family.collect(limit: Self.familyLimit) {
            children = related
                .filter { $0.parentID == id }
                .sorted(by: TaskRunsStore.newestFirst)
        }
    }

    /// Loads, then keeps the run current until it finishes or the calling task is cancelled (the
    /// screen goes away). A failed refresh of a loaded run doesn't stop it; the next one may work.
    /// A run that never loaded isn't watched: pull to refresh retries it.
    func watch() async {
        await load()
        guard isUnfinished else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.followCompletion() }
            group.addTask { await self.poll() }
            // Whichever side sees the run finish first ends the other. The stream ending without a
            // finished run (it failed) leaves polling to carry on alone.
            while await group.next() != nil {
                if !isUnfinished { group.cancelAll() }
            }
        }
        isStreaming = false
    }

    private func poll() async {
        while !Task.isCancelled, isUnfinished {
            try? await Task.sleep(for: isStreaming ? streamingRefreshInterval : refreshInterval)
            if Task.isCancelled { break }
            await load()
        }
    }

    /// Waits on Render's event stream for this run to finish, then reloads it once for its results
    /// and children. Returns early, leaving polling at full speed, if the stream fails.
    private func followCompletion() async {
        defer { isStreaming = false }
        do {
            for try await event in client.taskRunEvents.completions(of: [runID]) {
                switch event {
                case .connected:
                    isStreaming = true
                case .reconnecting:
                    isStreaming = false
                case .completed:
                    isStreaming = false
                    await load()
                    return
                }
            }
        } catch {
            // The stream is an optimisation over polling, which is still running; nothing to show.
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
