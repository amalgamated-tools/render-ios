import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Shapes copied from what the live API answered for the sample workflow's runs.
private enum RunJSON {
    static func attempt(_ number: Int, status: String, error: String? = nil) -> String {
        let errorField = error.map { #""error":"\#($0)","# } ?? ""
        return """
            {"attempt":\(number),"completedAt":"2026-11-21T17:52:1\(number + 6).000000Z",\
            "enqueuedAt":"2026-11-21T17:52:15.705646Z",\(errorField)"results":null,\
            "startedAt":"2026-11-21T17:52:1\(number + 5).000000Z","status":"\(status)","taskRunId":"trn-x"}
            """
    }

    static func run(
        id: String,
        status: String,
        startedAt: String? = "2026-11-21T17:52:15.000000Z",
        completedAt: String? = "2026-11-21T17:52:16.500000Z",
        parent: String = "",
        root: String? = nil,
        attempts: [String]? = nil
    ) -> String {
        let started = startedAt.map { #""startedAt":"\#($0)","# } ?? ""
        let completed = completedAt.map { #""completedAt":"\#($0)","# } ?? ""
        let attemptList = (attempts ?? [attempt(0, status: status)]).joined(separator: ",")
        return """
            {"attempts":[\(attemptList)],\(completed)"id":"\(id)","parentTaskRunId":"\(parent)",\
            "retries":0,"rootTaskRunId":"\(root ?? id)",\(started)"status":"\(status)","taskId":"tsk-1"}
            """
    }

    static func page(_ runs: [String]) -> String {
        "[" + runs.enumerated().map { #"{"cursor":"c\#($0.offset)","taskRun":\#($0.element)}"# }
            .joined(separator: ",") + "]"
    }

    /// The detail endpoint: a run plus `input`, `results` and `error`.
    static func detail(
        id: String = "trn-1",
        status: String,
        input: String = "[7]",
        results: String = "null",
        error: String? = nil,
        completedAt: String? = "2026-11-21T17:52:16.500000Z",
        parent: String = "",
        root: String? = nil,
        attempts: [String]? = nil
    ) -> String {
        let base = run(id: id, status: status, completedAt: completedAt, parent: parent, root: root, attempts: attempts)
        let errorField = error.map { #","error":"\#($0)""# } ?? ""
        return String(base.dropLast()) + #","input":\#(input),"results":\#(results)\#(errorField)}"#
    }
}

@MainActor
struct TaskRunsStoreTests {
    @Test func listsATasksRunsBySlugNewestFirst() async throws {
        let body = RunJSON.page([
            RunJSON.run(
                id: "trn-old", status: "completed",
                startedAt: "2026-11-21T10:00:00.000000Z", completedAt: "2026-11-21T10:00:01.500000Z"
            ),
            RunJSON.run(id: "trn-new", status: "running", startedAt: "2026-11-21T12:00:00.000000Z", completedAt: nil),
            RunJSON.run(id: "trn-queued", status: "pending", startedAt: nil, completedAt: nil),
        ])
        let (client, transport) = RenderClient.stubbed(jsonBodies: [body])
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))

        await store.load()

        #expect(store.runs.map(\.id) == ["trn-queued", "trn-new", "trn-old"])
        #expect(store.runs[1].status == .running)
        #expect(store.runs[2].duration == .milliseconds(1500))
        #expect(store.hasUnfinishedRuns)
        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("taskSlug=sample/square") || path.contains("taskSlug=sample%2Fsquare"))
    }

    @Test func namesEveryVersionSoOlderRunsStayListed() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [RunJSON.page([])])
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square", versions: ["new1234", "old5678"]))

        await store.load()

        let path = try #require(transport.requests.first?.path).removingPercentEncoding ?? ""
        #expect(path.contains("taskSlug=sample/square&"))
        #expect(path.contains("taskSlug=sample/square:new1234"))
        #expect(path.contains("taskSlug=sample/square:old5678"))
    }

    @Test func capsHowManyVersionsAreQueried() {
        let versions = (0..<50).map { "v\($0)" }
        let slugs = TaskRunsStore.taskSlugs(slug: "s/t", versions: versions)
        #expect(slugs.count == TaskRunsStore.maxVersionsQueried + 1)
        #expect(slugs.first == "s/t")
        #expect(slugs[1] == "s/t:v0")
    }

    @Test func listsAWorkflowsRunsByID() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: ["[]"])
        let store = TaskRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        await store.load()

        #expect(store.hasLoaded)
        #expect(store.runs.isEmpty)
        #expect(!store.hasUnfinishedRuns)
        #expect(try #require(transport.requests.first?.path).contains("workflowId=wfl-1"))
    }

    @Test func namesTheTasksInAWorkflowList() async {
        let runs = RunJSON.page([RunJSON.run(id: "trn-1", status: "completed")])
        let tasks = #"[{"cursor":"c0","task":{"createdAt":"2026-11-21T17:51:43Z","id":"tsk-1","name":"square","workflowId":"wfl-1","workflowVersionId":"wfv-1"}}]"#
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/tasks") ? (200, tasks) : (200, runs)
        }
        let store = TaskRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        await store.load()

        #expect(store.taskNames == ["tsk-1": "square"])
    }

    @Test func aFailedNameLookupStillShowsTheRuns() async {
        let runs = RunJSON.page([RunJSON.run(id: "trn-1", status: "completed")])
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/tasks") ? (500, #"{"message":"boom"}"#) : (200, runs)
        }
        let store = TaskRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        await store.load()

        #expect(store.runs.map(\.id) == ["trn-1"])
        #expect(store.taskNames.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func aTasksOwnListDoesntLookUpNames() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: ["[]"])
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))

        await store.load()

        #expect(transport.callCount == 1)
    }

    @Test func keepsRunsWhenAReloadFails() async {
        let (client, _) = RenderClient.stubbed(jsonBodies: [RunJSON.page([RunJSON.run(id: "trn-1", status: "completed")])])
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))
        await store.load()

        let (failing, _) = RenderClient.stubbed(jsonBodies: [#"{"message":"boom"}"#], status: 500)
        let reloaded = TaskRunsStore(client: failing, scope: .task(slug: "sample/square"))
        await reloaded.load()

        #expect(store.runs.count == 1)
        #expect(reloaded.errorMessage != nil)
        #expect(!reloaded.hasLoaded)
    }

    @Test func readsInputAsArrayObjectOrNothing() throws {
        #expect(try TaskRunsStore.parseInput("") == .case1([]))
        #expect(try TaskRunsStore.parseInput("  [7, \"x\"] ") == .case1([7, "x"]))
        guard case .case2(let object) = try TaskRunsStore.parseInput(#"{"a": 7}"#) else {
            Issue.record("expected an object")
            return
        }
        #expect(object.additionalProperties["a"] == 7)
        #expect(throws: TaskRunsStore.InputError.notJSON) { try TaskRunsStore.parseInput("[7") }
        #expect(throws: TaskRunsStore.InputError.notArrayOrObject) { try TaskRunsStore.parseInput("7") }
    }

    @Test func startsARunWithTheSlugAndAFreshKey() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [
            RunJSON.run(id: "trn-started", status: "pending", startedAt: nil, completedAt: nil),
            RunJSON.page([RunJSON.run(id: "trn-started", status: "pending", startedAt: nil, completedAt: nil)]),
        ], status: 202)
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))

        let id = await store.start(inputText: "[7]")

        #expect(id == "trn-started")
        #expect(store.startError == nil)
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.path == "/task-runs")
    }

    @Test func aRetryAfterAFailedStartReusesTheKey() async {
        let (client, keys) = keyRecording { _ in (500, #"{"message":"boom"}"#) }
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))

        #expect(await store.start(inputText: "[7]") == nil)
        #expect(await store.start(inputText: "[7]") == nil)
        #expect(await store.start(inputText: "[8]") == nil)

        #expect(keys.values.count == 3)
        #expect(keys.values[0] == keys.values[1], "same input again: same key, so Render can't run it twice")
        #expect(keys.values[1] != keys.values[2], "different input: a new run, so a new key")
    }

    @Test func aSuccessfulStartGetsANewKeyNextTime() async {
        let started = RunJSON.run(id: "trn-started", status: "pending", startedAt: nil, completedAt: nil)
        let (client, keys) = keyRecording { method in
            method == .post ? (202, started) : (200, RunJSON.page([started]))
        }
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))

        #expect(await store.start(inputText: "[7]") == "trn-started")
        #expect(await store.start(inputText: "[7]") == "trn-started")

        #expect(keys.values.count == 2)
        #expect(keys.values[0] != keys.values[1], "running the same input twice on purpose starts two runs")
    }

    @Test func badInputIsNeverSent() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: ["{}"])
        let store = TaskRunsStore(client: client, scope: .task(slug: "sample/square"))

        let id = await store.start(inputText: "seven")

        #expect(id == nil)
        #expect(store.startError == TaskRunsStore.InputError.notJSON.errorDescription)
        #expect(transport.callCount == 0)
    }

    @Test func aWorkflowListCantStartARun() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: ["{}"])
        let store = TaskRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        #expect(await store.start(inputText: "[]") == nil)
        #expect(transport.callCount == 0)
    }
}

@MainActor
struct TaskRunDetailStoreTests {
    @Test func loadsAFailedRunWithItsRetries() async throws {
        let detail = RunJSON.detail(
            status: "failed",
            input: "[]",
            error: "failed on purpose",
            attempts: [
                RunJSON.attempt(1, status: "failed", error: "failed on purpose"),
                RunJSON.attempt(0, status: "failed", error: "failed on purpose"),
            ]
        )
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/task-runs/trn-1") ? (200, detail) : (200, "[]")
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")

        await store.load()

        let run = try #require(store.run)
        #expect(run.status == .failed)
        #expect(run.error == "failed on purpose")
        #expect(run.results == nil)
        #expect(run.input == "[\n\n]")
        #expect(run.attempts.map(\.number) == [1, 2])
        #expect(!store.canCancel)
    }

    @Test func looksUpTheTasksName() async {
        let detail = RunJSON.detail(status: "completed", results: "[49]")
        let task = #"{"createdAt":"2026-11-21T17:51:43Z","id":"tsk-1","name":"square","workflowId":"wfl-1","workflowVersionId":"wfv-1"}"#
        let (client, _) = RenderClient.routed { path in
            if path.hasPrefix("/tasks/tsk-1") { return (200, task) }
            return path.hasPrefix("/task-runs/trn-1") ? (200, detail) : (200, "[]")
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")

        await store.load()

        #expect(store.taskName == "square")
        #expect(store.run?.results == "49")
    }

    @Test func showsTheResultValueAndTheRunsItStarted() async throws {
        let detail = RunJSON.detail(status: "completed", input: "[3]", results: "[14]")
        let family = RunJSON.page([
            RunJSON.run(id: "trn-1", status: "completed"),
            RunJSON.run(id: "trn-child", status: "completed", parent: "trn-1", root: "trn-1"),
            RunJSON.run(id: "trn-grandchild", status: "completed", parent: "trn-child", root: "trn-1"),
        ])
        let (client, transport) = RenderClient.routed { path in
            path.hasPrefix("/task-runs/trn-1") ? (200, detail) : (200, family)
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")

        await store.load()

        #expect(store.run?.results == "14")
        #expect(store.children.map(\.id) == ["trn-child"])
        #expect(transport.requests.contains { $0.path?.contains("rootTaskRunId=trn-1") == true })
    }

    @Test func aChildRunListsItsOwnChildrenThroughTheRoot() async throws {
        let detail = RunJSON.detail(id: "trn-child", status: "completed", parent: "trn-root", root: "trn-root")
        let family = RunJSON.page([
            RunJSON.run(id: "trn-root", status: "completed"),
            RunJSON.run(id: "trn-child", status: "completed", parent: "trn-root", root: "trn-root"),
            RunJSON.run(id: "trn-grandchild", status: "completed", parent: "trn-child", root: "trn-root"),
        ])
        let (client, transport) = RenderClient.routed { path in
            path.hasPrefix("/task-runs/trn-child") ? (200, detail) : (200, family)
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-child")

        await store.load()

        #expect(store.children.map(\.id) == ["trn-grandchild"])
        #expect(transport.requests.contains { $0.path?.contains("rootTaskRunId=trn-root") == true })
    }

    @Test func aFailedChildrenListStillShowsTheRun() async {
        let running = RunJSON.detail(status: "running", completedAt: nil)
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/task-runs/trn-1") ? (200, running) : (500, #"{"message":"boom"}"#)
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")

        await store.load()

        #expect(store.run?.status == .running)
        #expect(store.errorMessage == nil)
        #expect(store.canCancel)
    }

    @Test func cancelsARunningRunAndReloads() async throws {
        let running = RunJSON.detail(status: "running", completedAt: nil)
        let canceled = RunJSON.detail(status: "canceled")
        let wasCanceled = LockedFlag()
        let (client, transport) = methodRouted { method, path in
            if method == .delete {
                wasCanceled.value = true
                return (204, "")
            }
            if path.hasPrefix("/task-runs/trn-1") { return (200, wasCanceled.value ? canceled : running) }
            return (200, "[]")
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")
        await store.load()
        #expect(store.canCancel)

        await store.cancel()

        #expect(store.actionResult?.isFailure == false)
        #expect(store.run?.status == .canceled)
        #expect(!store.canCancel)
        #expect(transport.requests.contains { $0.method == .delete && $0.path == "/task-runs/trn-1" })
    }

    @Test func aFailedCancelSaysSoAndKeepsTheRun() async {
        let running = RunJSON.detail(status: "running", completedAt: nil)
        let (client, _) = methodRouted { method, path in
            if method == .delete { return (409, #"{"message":"already finishing"}"#) }
            return path.hasPrefix("/task-runs/trn-1") ? (200, running) : (200, "[]")
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")
        await store.load()

        await store.cancel()

        #expect(store.actionResult?.isFailure == true)
        #expect(store.actionResult?.message.hasPrefix("Couldn't cancel") == true)
        #expect(store.run?.status == .running)
        #expect(store.canCancel)
    }

    @Test func watchStopsOnceTheRunFinishes() async {
        let fetches = FetchCounter()
        let (client, _) = methodRouted { _, path in
            guard path.hasPrefix("/task-runs/trn-1") else { return (200, "[]") }
            return fetches.next() < 2
                ? (200, RunJSON.detail(status: "running", completedAt: nil))
                : (200, RunJSON.detail(status: "completed", results: "[1]"))
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1", refreshInterval: .milliseconds(1))

        await store.watch()

        #expect(store.run?.status == .completed)
        #expect(fetches.count == 3)
    }

    @Test func watchGivesUpWhenTheRunCantBeLoaded() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [#"{"message":"not found"}"#], status: 404)
        let store = TaskRunDetailStore(client: client, runID: "trn-1", refreshInterval: .milliseconds(1))

        await store.watch()

        #expect(store.run == nil)
        #expect(store.errorMessage != nil)
        #expect(transport.callCount == 1, "one load, which stops at the missing run, then no polling")
    }

    @Test func cancelIsntOfferedForAFinishedRun() async {
        let (client, transport) = methodRouted { _, path in
            path.hasPrefix("/task-runs/trn-1") ? (200, RunJSON.detail(status: "completed")) : (200, "[]")
        }
        let store = TaskRunDetailStore(client: client, runID: "trn-1")
        await store.load()

        await store.cancel()

        #expect(store.actionResult == nil)
        #expect(!transport.requests.contains { $0.method == .delete })
    }
}

