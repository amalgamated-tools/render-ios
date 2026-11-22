import Foundation
import Observation
import RenderAPI

/// Recent runs of one task, or of every task in a workflow, newest first, and starting a new run.
///
/// **Which runs.** A task is filtered by slug, not ID, since every version registers the task afresh
/// with a new ID. A bare slug (`workflow-slug/task-name`) only matches the latest version's runs, so
/// the query also names each known version (`workflow-slug/task-name:version-name`). Render answers
/// a list mixing valid and unknown versions with the runs of the valid ones, and the bare slug keeps
/// at least one valid. A workflow is filtered by its ID.
///
/// Only the newest page is loaded. This is a phone screen for "what just happened", not an archive.
@MainActor
@Observable
final class TaskRunsStore {
    enum Scope: Sendable, Equatable {
        case workflow(id: String)
        /// `versions` are version names, newest first; older runs than these aren't listed.
        case task(slug: String, versions: [String] = [])
    }

    /// Bounds the query string for a workflow with a long history.
    nonisolated static let maxVersionsQueried = 20

    /// The bare slug plus one versioned slug per known version. Flow slugs work the same way.
    nonisolated static func taskSlugs(slug: String, versions: [String]) -> [String] {
        [slug] + versions.prefix(maxVersionsQueried).map { "\(slug):\($0)" }
    }

    private(set) var runs: [TaskRunSummary] = []
    /// Task names by ID, for a workflow-wide list, whose runs only carry the task's ID. Empty when
    /// the lookup failed; rows then show the ID.
    private(set) var taskNames: [String: String] = [:]
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

    /// True while any run on screen might still change, so the screen knows to keep refreshing.
    var hasUnfinishedRuns: Bool { runs.contains { !$0.status.isFinished } }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let query: Operations.ListTaskRuns.Input.Query = switch scope {
        case .workflow(let id): .init(limit: limit, workflowId: [id])
        case .task(let slug, let versions): .init(limit: limit, taskSlug: Self.taskSlugs(slug: slug, versions: versions))
        }
        do {
            async let names = taskNamesIfNeeded()
            let page = try await client.api.listTaskRuns(query: query).ok.body.json
            runs = page.map { TaskRunSummary($0.taskRun) }.sorted(by: Self.newestFirst)
            if let loaded = await names { taskNames = loaded }
            errorMessage = nil
            hasLoaded = true
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// Every version registers its own copy of each task, so one page of tasks covers the recent
    /// versions' IDs. Only fetched once, and never for a single task's list, which knows its name.
    private func taskNamesIfNeeded() async -> [String: String]? {
        guard case .workflow(let id) = scope, taskNames.isEmpty else { return nil }
        guard let tasks = try? await client.api.listTasks(query: .init(workflowId: [id], limit: 100)).ok.body.json else {
            return nil
        }
        return Dictionary(tasks.map { ($0.task.id, $0.task.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// Runs not yet started sort first, since they're the newest.
    nonisolated static func newestFirst(_ a: TaskRunSummary, _ b: TaskRunSummary) -> Bool {
        switch (a.startedAt, b.startedAt) {
        case let (a?, b?): a > b
        case (nil, _?): true
        case (_?, nil): false
        case (nil, nil): a.id > b.id
        }
    }

    // MARK: - Starting a run

    enum InputError: LocalizedError, Equatable {
        case notJSON
        case notArrayOrObject

        var errorDescription: String? {
            switch self {
            case .notJSON: "That isn't valid JSON."
            case .notArrayOrObject:
                "Input must be a JSON array of arguments, like [7], or an object of named arguments, like {\"a\": 7}."
            }
        }
    }

    /// Reads what was typed as a task's input: an array of positional arguments or an object of
    /// named ones. Blank means no arguments.
    nonisolated static func parseInput(_ text: String) throws(InputError) -> Operations.CreateTask.Input.Body.JsonPayload.InputPayload {
        try parseInput(text, empty: .case1([]))
    }

    /// The same for any run input type (a flow run's input has its own generated type). `empty` is
    /// what blank input means.
    nonisolated static func parseInput<Input: Decodable>(_ text: String, empty: Input) throws(InputError) -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return empty }
        guard let data = trimmed.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil else {
            throw .notJSON
        }
        guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
              let input = try? JSONDecoder().decode(Input.self, from: data) else {
            throw .notArrayOrObject
        }
        return input
    }

    /// Starts a run of this task with the typed input and returns the new run's ID, or nil when it
    /// couldn't start (with `startError` saying why). Only a task can be started, not a workflow.
    ///
    /// The run starts on the version Render currently uses for the task, the same as a run started
    /// without a version from the CLI.
    ///
    /// **Idempotency.** A failed start may still have reached Render (a lost response, or a 5xx
    /// after it accepted the run), and POSTs aren't retried automatically. So the key outlives a
    /// failure: trying the same input again reuses it, and Render won't start a second run. A
    /// success, or different input, gets a new key.
    func start(inputText: String) async -> String? {
        guard case .task(let slug, _) = scope, !isStarting else { return nil }
        let input: Operations.CreateTask.Input.Body.JsonPayload.InputPayload
        do {
            input = try Self.parseInput(inputText)
        } catch {
            startError = error.errorDescription
            return nil
        }

        let key = unconfirmedStart.flatMap { $0.input == inputText ? $0.key : nil } ?? UUID().uuidString
        unconfirmedStart = (inputText, key)

        isStarting = true
        defer { isStarting = false }
        do {
            let run = try await client.api.createTask(body: .json(.init(
                task: slug, input: input, idempotencyKey: key
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
