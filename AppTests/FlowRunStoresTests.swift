import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Shapes copied from what the live API answered for the sample workflow's `double_and_describe`.
private enum FlowJSON {
    static func run(
        id: String,
        status: String,
        startedAt: String? = "2026-11-21T17:52:16.574740Z",
        completedAt: String? = "2026-11-21T17:52:17.539014Z"
    ) -> String {
        let started = startedAt.map { #","startedAt":"\#($0)""# } ?? ""
        let completed = completedAt.map { #","completedAt":"\#($0)""# } ?? ""
        return #"{"flowId":"flw-1","id":"\#(id)","status":"\#(status)"\#(started)\#(completed)}"#
    }

    static func page(_ runs: [String]) -> String {
        "[" + runs.enumerated().map { #"{"cursor":"c\#($0.offset)","flowRun":\#($0.element)}"# }
            .joined(separator: ",") + "]"
    }

    static let succeeded = """
        {"attempts":[{"attempt":0,"completedAt":"2026-11-21T17:52:17.539014Z","startedAt":"2026-11-21T17:52:16.878685Z","status":"succeeded"}],\
        "completedAt":"2026-11-21T17:52:17.539014Z","flowId":"flw-1","id":"frn-1","input":[5],\
        "results":["the answer is 10"],"startedAt":"2026-11-21T17:52:16.57474Z","status":"succeeded"}
        """

    /// A run started with no input: Render sends `[]` for its results, not `null`.
    static let failed = """
        {"attempts":[{"attempt":0,"completedAt":"2026-11-21T18:53:09.919879Z","error":"missing x","startedAt":"2026-11-21T18:53:09.479007Z","status":"failed"}],\
        "completedAt":"2026-11-21T18:53:09.919879Z","error":"missing x","flowId":"flw-1","id":"frn-1",\
        "input":[],"results":[],"startedAt":"2026-11-21T18:53:09.15535Z","status":"failed"}
        """

    static let running = """
        {"attempts":[],"flowId":"flw-1","id":"frn-1","input":[5],"results":[],\
        "startedAt":"2026-11-21T17:52:16.57474Z","status":"running"}
        """

    static let canceled = running.replacingOccurrences(of: #""status":"running""#, with: #""status":"canceled""#)

    /// In the order Render lists them: the order the flow started them.
    static let steps = """
        {"hasMore":false,"steps":[\
        {"completedAt":"2026-11-21T17:52:17.364Z","name":"double","seq":0,"startedAt":"2026-11-21T17:52:17.301Z","status":"succeeded","stepKey":"","type":"inline"},\
        {"completedAt":"2026-11-21T17:52:17.469Z","name":"describe","seq":1,"startedAt":"2026-11-21T17:52:17.436Z","status":"succeeded","stepKey":"","type":"inline"},\
        {"childTaskRunId":"trn-9","name":"","seq":2,"startedAt":"2026-11-21T17:52:17.500Z","status":"running","stepKey":"","type":"detached"}]}
        """

    static let noSteps = #"{"hasMore":false,"steps":[]}"#

    /// One step run in a loop: three iterations share seq 0, keyed "2", "10" and "1" in the order
    /// they started, which sorting the keys would scramble.
    static let repeatedSteps = """
        {"hasMore":false,"steps":[\
        {"name":"tick","seq":0,"startedAt":"2026-11-21T17:52:17.100Z","status":"succeeded","stepKey":"2","type":"inline"},\
        {"name":"tick","seq":0,"startedAt":"2026-11-21T17:52:17.200Z","status":"succeeded","stepKey":"10","type":"inline"},\
        {"name":"tick","seq":0,"startedAt":"2026-11-21T17:52:17.300Z","status":"succeeded","stepKey":"1","type":"inline"}]}
        """

    static let flow = #"{"createdAt":"2026-11-21T17:51:43.441888Z","id":"flw-1","name":"double_and_describe","workflowId":"wfl-1","workflowVersionId":"wfv-1"}"#

    static let step = """
        {"completedAt":"2026-11-21T17:52:17.364Z","input":[5],"name":"double","result":10,"seq":0,\
        "startedAt":"2026-11-21T17:52:17.301Z","status":"succeeded","stepKey":"","type":"inline"}
        """
}

@MainActor
struct FlowRunsStoreTests {
    @Test func listsAFlowsRunsBySlugNewestFirst() async throws {
        let body = FlowJSON.page([
            FlowJSON.run(id: "frn-old", status: "succeeded", startedAt: "2026-11-21T10:00:00.000000Z", completedAt: "2026-11-21T10:00:01.000000Z"),
            FlowJSON.run(id: "frn-queued", status: "pending", startedAt: nil, completedAt: nil),
            FlowJSON.run(id: "frn-new", status: "failed", startedAt: "2026-11-21T12:00:00.000000Z"),
        ])
        let (client, transport) = RenderClient.stubbed(jsonBodies: [body])
        let store = FlowRunsStore(client: client, scope: .flow(slug: "sample/double_and_describe"))

        await store.load()

        #expect(store.runs.map(\.id) == ["frn-queued", "frn-new", "frn-old"])
        #expect(store.runs[2].duration == .seconds(1))
        #expect(store.hasUnfinishedRuns)
        #expect(transport.callCount == 1, "a flow's own list doesn't look up names")
        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/flow-runs"))
        #expect(path.contains("flowSlug=sample%2Fdouble_and_describe"), "the slash is percent-encoded; Render accepts that")
    }

    @Test func namesTheFlowsInAWorkflowList() async {
        let runs = FlowJSON.page([FlowJSON.run(id: "frn-1", status: "succeeded")])
        let flows = #"[{"cursor":"c0","flow":\#(FlowJSON.flow)}]"#
        let (client, transport) = RenderClient.routed { path in
            path.hasPrefix("/flows") ? (200, flows) : (200, runs)
        }
        let store = FlowRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        await store.load()

        #expect(store.flowNames == ["flw-1": "double_and_describe"])
        #expect(!store.hasUnfinishedRuns)
        #expect(transport.requests.contains { $0.path?.contains("/flow-runs?") == true && $0.path?.contains("workflowId=wfl-1") == true })
    }

    @Test func aFailedNameLookupStillShowsTheRuns() async {
        let runs = FlowJSON.page([FlowJSON.run(id: "frn-1", status: "succeeded")])
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/flows") ? (500, #"{"message":"boom"}"#) : (200, runs)
        }
        let store = FlowRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        await store.load()

        #expect(store.runs.map(\.id) == ["frn-1"])
        #expect(store.flowNames.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test func startsARunWithTheSlugAndAFreshKey() async throws {
        let sent = BodyBox()
        let transport = StubTransport { request, body, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields = [.contentType: "application/json"]
            if request.method == .post {
                if let body { sent.data = try await Data(collecting: body, upTo: 4096) }
                response.status = .accepted
                return (response, HTTPBody(FlowJSON.run(id: "frn-started", status: "pending", completedAt: nil)))
            }
            return (response, HTTPBody(FlowJSON.page([FlowJSON.run(id: "frn-started", status: "pending", completedAt: nil)])))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        let store = FlowRunsStore(client: client, scope: .flow(slug: "sample/double_and_describe"))

        let id = await store.start(inputText: "[5]")

        #expect(id == "frn-started")
        #expect(store.startError == nil)
        #expect(store.runs.map(\.id) == ["frn-started"], "the list reloads after starting")
        let request = try #require(transport.requests.first)
        #expect(request.method == .post)
        #expect(request.path == "/flow-runs")
        let json = try #require(try JSONSerialization.jsonObject(with: sent.data) as? [String: Any])
        #expect(json["flow"] as? String == "sample/double_and_describe")
        #expect(json["input"] as? [Int] == [5])
        #expect((json["idempotencyKey"] as? String)?.isEmpty == false)
    }

    @Test func aFlowsListNamesEveryVersionSoOlderRunsStayListed() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [FlowJSON.page([])])
        let store = FlowRunsStore(client: client, scope: .flow(slug: "sample/flow", versions: ["v2", "v1"]))

        await store.load()

        let path = try #require(transport.requests.first?.path).removingPercentEncoding ?? ""
        #expect(path.contains("flowSlug=sample/flow&"), "the bare slug keeps the query valid")
        #expect(path.contains("flowSlug=sample/flow:v2"))
        #expect(path.contains("flowSlug=sample/flow:v1"))
    }

    @Test func aRetryAfterAFailedStartReusesTheKey() async {
        let (client, keys) = keyRecording { _ in (500, #"{"message":"boom"}"#) }
        let store = FlowRunsStore(client: client, scope: .flow(slug: "sample/flow"))

        #expect(await store.start(inputText: "[5]") == nil)
        #expect(await store.start(inputText: "[5]") == nil)
        #expect(await store.start(inputText: "[6]") == nil)

        #expect(keys.values.count == 3)
        #expect(keys.values[0] == keys.values[1], "same input again: same key, so Render can't run it twice")
        #expect(keys.values[1] != keys.values[2], "different input: a new run, so a new key")
    }

    @Test func aSuccessfulStartGetsANewKeyNextTime() async {
        let started = FlowJSON.run(id: "frn-started", status: "pending", completedAt: nil)
        let (client, keys) = keyRecording { method in
            method == .post ? (202, started) : (200, FlowJSON.page([started]))
        }
        let store = FlowRunsStore(client: client, scope: .flow(slug: "sample/flow"))

        #expect(await store.start(inputText: "[5]") == "frn-started")
        #expect(await store.start(inputText: "[5]") == "frn-started")

        #expect(keys.values.count == 2)
        #expect(keys.values[0] != keys.values[1], "running the same input twice on purpose starts two runs")
    }

    @Test func badInputIsNeverSent() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: ["{}"])
        let store = FlowRunsStore(client: client, scope: .flow(slug: "sample/double_and_describe"))

        #expect(await store.start(inputText: "5") == nil)
        #expect(store.startError == TaskRunsStore.InputError.notArrayOrObject.errorDescription)
        #expect(transport.callCount == 0)
    }

    @Test func aWorkflowListCantStartARun() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: ["{}"])
        let store = FlowRunsStore(client: client, scope: .workflow(id: "wfl-1"))

        #expect(await store.start(inputText: "[]") == nil)
        #expect(transport.callCount == 0)
    }
}

@MainActor
struct FlowRunDetailStoreTests {
    private func routes(detail: @escaping @Sendable () -> String, steps: String = FlowJSON.steps)
        -> (client: RenderClient, transport: StubTransport) {
        methodRouted { method, path in
            if method == .delete { return (204, "") }
            if path.hasPrefix("/flow-runs/frn-1/steps") { return (200, steps) }
            if path.hasPrefix("/flow-runs/frn-1") { return (200, detail()) }
            if path.hasPrefix("/flows/flw-1") { return (200, FlowJSON.flow) }
            return (404, #"{"message":"not found"}"#)
        }
    }

    @Test func loadsARunWithItsStepsInOrder() async throws {
        let (client, _) = routes(detail: { FlowJSON.succeeded })
        let store = FlowRunDetailStore(client: client, runID: "frn-1")

        await store.load()

        let run = try #require(store.run)
        #expect(run.status == .succeeded)
        #expect(run.results == #""the answer is 10""#)
        #expect(run.error == nil)
        #expect(store.flowName == "double_and_describe")
        #expect(store.steps.map(\.name) == ["double", "describe", "Step 3"])
        #expect(store.steps[2].kind == .detached)
        #expect(store.steps[2].childTaskRunID == "trn-9")
        #expect(store.steps[0].childTaskRunID == nil)
        #expect(store.steps[0].duration == .milliseconds(62), "17.364 - 17.301, truncated to whole milliseconds")
        #expect(!store.hasMoreSteps)
        #expect(!store.canCancel)
    }

    @Test func repeatedStepsKeepTheOrderTheyStartedIn() async {
        let (client, _) = routes(detail: { FlowJSON.succeeded }, steps: FlowJSON.repeatedSteps)
        let store = FlowRunDetailStore(client: client, runID: "frn-1", flowName: "x")

        await store.load()

        #expect(store.steps.map(\.stepKey) == ["2", "10", "1"])
    }

    @Test func aFailedStepsListStillShowsTheRun() async throws {
        let stepsFail = LockedFlag()
        let (client, _) = methodRouted { _, path in
            if path.hasPrefix("/flow-runs/frn-1/steps") {
                return stepsFail.value ? (500, #"{"message":"boom"}"#) : (200, FlowJSON.steps)
            }
            return (200, FlowJSON.running)
        }
        let store = FlowRunDetailStore(client: client, runID: "frn-1", flowName: "x")
        await store.load()
        stepsFail.value = true

        await store.load()

        #expect(store.run?.status == .running)
        #expect(store.errorMessage == nil)
        #expect(store.steps.count == 3, "the steps from the last load stay")
    }

    @Test func aRunWhoseStepsNeverLoadStillShows() async {
        let (client, _) = methodRouted { _, path in
            path.hasPrefix("/flow-runs/frn-1/steps") ? (500, #"{"message":"boom"}"#) : (200, FlowJSON.succeeded)
        }
        let store = FlowRunDetailStore(client: client, runID: "frn-1", flowName: "x")

        await store.load()

        #expect(store.run?.status == .succeeded)
        #expect(store.steps.isEmpty)
    }

    @Test func aFailedRunHasNoResultAndNoSteps() async throws {
        let (client, _) = routes(detail: { FlowJSON.failed }, steps: FlowJSON.noSteps)
        let store = FlowRunDetailStore(client: client, runID: "frn-1", flowName: "double_and_describe")

        await store.load()

        let run = try #require(store.run)
        #expect(run.status == .failed)
        #expect(run.results == nil, "Render sends [] before a flow returns")
        #expect(run.error == "missing x")
        #expect(run.attempts.map(\.number) == [1])
        #expect(store.steps.isEmpty)
    }

    @Test func aKnownNameIsntLookedUpAgain() async {
        let (client, transport) = routes(detail: { FlowJSON.succeeded })
        let store = FlowRunDetailStore(client: client, runID: "frn-1", flowName: "known")

        await store.load()

        #expect(store.flowName == "known")
        #expect(!transport.requests.contains { $0.path?.hasPrefix("/flows/") == true })
    }

    @Test func cancelsARunningRunAndReloads() async throws {
        let wasCanceled = LockedFlag()
        let (client, transport) = methodRouted { method, path in
            if method == .delete {
                wasCanceled.value = true
                return (204, "")
            }
            if path.hasPrefix("/flow-runs/frn-1/steps") { return (200, FlowJSON.noSteps) }
            if path.hasPrefix("/flow-runs/frn-1") { return (200, wasCanceled.value ? FlowJSON.canceled : FlowJSON.running) }
            return (200, FlowJSON.flow)
        }
        let store = FlowRunDetailStore(client: client, runID: "frn-1")
        await store.load()
        #expect(store.canCancel)

        await store.cancel()

        #expect(store.actionResult?.isFailure == false)
        #expect(store.run?.status == .canceled)
        #expect(transport.requests.contains { $0.method == .delete && $0.path == "/flow-runs/frn-1" })
    }

    @Test func aFailedCancelSaysSoAndKeepsTheRun() async {
        let (client, _) = methodRouted { method, path in
            if method == .delete { return (409, #"{"message":"already finishing"}"#) }
            if path.hasPrefix("/flow-runs/frn-1/steps") { return (200, FlowJSON.noSteps) }
            return path.hasPrefix("/flow-runs/frn-1") ? (200, FlowJSON.running) : (200, FlowJSON.flow)
        }
        let store = FlowRunDetailStore(client: client, runID: "frn-1")
        await store.load()

        await store.cancel()

        #expect(store.actionResult?.message.hasPrefix("Couldn't cancel") == true)
        #expect(store.run?.status == .running)
    }

    @Test func watchStopsOnceTheRunFinishes() async {
        let fetches = FetchCounter()
        let (client, _) = routes(detail: { fetches.next() < 2 ? FlowJSON.running : FlowJSON.succeeded })
        let store = FlowRunDetailStore(client: client, runID: "frn-1", flowName: "x", refreshInterval: .milliseconds(1))

        await store.watch()

        #expect(store.run?.status == .succeeded)
        #expect(fetches.count == 3)
    }

    @Test func watchGivesUpWhenTheRunCantBeLoaded() async {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [#"{"message":"not found"}"#], status: 404)
        let store = FlowRunDetailStore(client: client, runID: "frn-1", refreshInterval: .milliseconds(1))

        await store.watch()

        #expect(store.run == nil)
        #expect(store.errorMessage != nil)
        #expect(transport.callCount == 2, "one load: the run and its steps, then no polling")
    }

    @Test func loadsAStepsInputAndResult() async throws {
        let (listClient, _) = routes(detail: { FlowJSON.succeeded })
        let run = FlowRunDetailStore(client: listClient, runID: "frn-1", flowName: "x")
        await run.load()
        let step = try #require(run.steps.first)
        let (client, transport) = RenderClient.stubbed(jsonBodies: [FlowJSON.step])
        let store = FlowRunStepStore(client: client, runID: "frn-1", step: step)

        await store.load()

        #expect(store.detail?.input == "[\n  5\n]")
        #expect(store.detail?.result == "10")
        #expect(store.detail?.error == nil)
        #expect(transport.requests.first?.path == "/flow-runs/frn-1/steps/0", "no empty stepKey sent")
    }

    @Test func aStepThatFinishedSinceTheListShowsItsNewStatus() async throws {
        let (listClient, _) = routes(detail: { FlowJSON.running })
        let run = FlowRunDetailStore(client: listClient, runID: "frn-1", flowName: "x")
        await run.load()
        let step = try #require(run.steps.last)
        #expect(step.status == .running)
        let finished = """
            {"childTaskRunId":"trn-9","completedAt":"2026-11-21T17:52:18.500Z","name":"","result":7,"seq":2,\
            "startedAt":"2026-11-21T17:52:17.500Z","status":"succeeded","stepKey":"","type":"detached"}
            """
        let (client, _) = RenderClient.stubbed(jsonBodies: [finished])
        let store = FlowRunStepStore(client: client, runID: "frn-1", step: step)

        await store.load()

        #expect(store.step.status == .succeeded)
        #expect(store.step.duration == .seconds(1))
        #expect(store.step.id == step.id)
        #expect(store.detail?.result == "7")
    }
}

private final class BodyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _data = Data()
    var data: Data {
        get { lock.withLock { _data } }
        set { lock.withLock { _data = newValue } }
    }
}
