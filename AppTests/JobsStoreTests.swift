import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Job JSON in the shape the spec gives every job operation.
private func job(
    id: String,
    status: String,
    command: String = "npm run migrate",
    startedAt: String? = nil,
    finishedAt: String? = nil
) -> String {
    var fields = [
        #""id":"\#(id)""#,
        #""serviceId":"srv-1""#,
        #""startCommand":"\#(command)""#,
        #""planId":"plan-srv-008""#,
        #""status":"\#(status)""#,
        #""createdAt":"2026-11-14T10:00:00Z""#,
    ]
    if let startedAt { fields.append(#""startedAt":"\#(startedAt)""#) }
    if let finishedAt { fields.append(#""finishedAt":"\#(finishedAt)""#) }
    return "{\(fields.joined(separator: ","))}"
}

private func page(_ jobs: [String]) -> String {
    "[" + jobs.enumerated().map { #"{"job":\#($1),"cursor":"c\#($0)"}"# }.joined(separator: ",") + "]"
}

@MainActor
@Suite("JobsStore")
struct JobsStoreTests {
    @Test("the list loads newest-first as Render returns it")
    func loadsList() async {
        let (client, _) = RenderClient.routed { _ in
            (200, page([job(id: "job-2", status: "running"), job(id: "job-1", status: "succeeded")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pageSize: 20)

        await store.refresh()
        store.stopPolling()

        #expect(store.jobs.map(\.id) == ["job-2", "job-1"])
        #expect(store.jobs.first?.isActive == true)
        #expect(store.hasMore == false)
    }

    @Test("starting sends the trimmed command and puts the new job at the top")
    func startSendsCommand() async throws {
        let recorder = BodyRecorder()
        let store = JobsStore(
            client: recorder.client(answering: job(id: "job-9", status: "pending"), status: 201),
            serviceID: "srv-1",
            pollInterval: .seconds(60)
        )

        let started = await store.start(command: "  rails db:migrate \n")
        store.stopPolling()

        #expect(started)
        let body = try #require(recorder.bodies.first)
        let sent = try JSONDecoder().decode([String: String].self, from: Data(body.utf8))
        #expect(sent == ["startCommand": "rails db:migrate"])
        #expect(store.jobs.first?.id == "job-9")
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("an empty command never reaches Render")
    func emptyCommandIsIgnored() async {
        let recorder = BodyRecorder()
        let store = JobsStore(client: recorder.client(answering: "{}"), serviceID: "srv-1")

        let started = await store.start(command: "   ")

        #expect(!started)
        #expect(recorder.requests.isEmpty)
    }

    @Test("Render's own refusal is what the banner says")
    func freePlanRefusalIsShown() async {
        // The live answer for a Free-plan service.
        let (client, _) = RenderClient.routed { _ in
            (400, #"{"id":"invalid-input","message":"free tier plans are not supported for jobs"}"#)
        }
        let store = JobsStore(client: client, serviceID: "srv-1")

        let started = await store.start(command: "echo hi")

        #expect(!started)
        #expect(store.actionResult?.isFailure == true)
        #expect(store.actionResult?.message == "Free tier plans are not supported for jobs.")
        #expect(store.jobs.isEmpty)
    }

    @Test("Start is unavailable on Free and left to Render everywhere else")
    func startUnavailableReason() {
        #expect(JobsStore.startUnavailableReason(plan: .free) != nil)
        #expect(JobsStore.startUnavailableReason(plan: .starter) == nil)
        #expect(JobsStore.startUnavailableReason(plan: nil) == nil)
    }

    @Test("cancelling replaces the row with the job Render sends back")
    func cancelReplacesRow() async {
        let (client, _) = RenderClient.routed { path in
            path.hasSuffix("/cancel")
                ? (200, job(id: "job-1", status: "canceled", finishedAt: "2026-11-14T10:01:00Z"))
                : (200, page([job(id: "job-1", status: "running")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pollInterval: .seconds(60))
        await store.refresh()

        await store.cancel(jobID: "job-1")

        #expect(store.job(id: "job-1")?.status == .canceled)
        #expect(store.actionResult?.message == "Job canceled.")
        #expect(store.writeInFlight == nil)
    }

    @Test("a failed cancel re-reads the job, which may simply have finished first")
    func failedCancelRereads() async {
        let (client, _) = RenderClient.routed { path in
            // Render's live answer when the job has already finished.
            if path.hasSuffix("/cancel") { return (400, #"{"message":"cannot cancel job that isn't running"}"#) }
            if path.hasSuffix("/jobs/job-1") { return (200, job(id: "job-1", status: "succeeded")) }
            return (200, page([job(id: "job-1", status: "running")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pollInterval: .seconds(60))
        await store.refresh()

        await store.cancel(jobID: "job-1")

        #expect(store.actionResult?.message == "Cannot cancel job that isn't running.")
        #expect(store.job(id: "job-1")?.status == .succeeded)
    }

    @Test("a real job list decodes: all three end states, nanosecond times, and no finish time while running")
    func decodesLiveList() async throws {
        // `GET /services/{id}/jobs` from a live Starter service, two minutes after starting
        // `echo … && sleep 5`, `sleep 600` and `sh -c "exit 3"`.
        let live = #"""
        [{"cursor":"nPvoDMxI6tFxM2pyamxoczczY2x2Zjdn","job":{"createdAt":"2026-11-14T05:09:34.074844Z","finishedAt":"2026-11-14T05:09:41Z","id":"job-dbruq3jrjlhs73clvf7g","planId":"plan-srv-006","serviceId":"srv-dbrupgm1egvs73cbq8m0","startCommand":"sh -c \"exit 3\"","startedAt":"2026-11-14T05:09:34Z","status":"failed"}},{"cursor":"nPvoDMxI6tFxM2JsNTUwczczZXY0a3Mw","job":{"createdAt":"2026-11-14T05:09:33.752743Z","id":"job-dbruq3bl550s73ev4ks0","planId":"plan-srv-006","serviceId":"srv-dbrupgm1egvs73cbq8m0","startCommand":"sleep 600","startedAt":"2026-11-14T05:09:33Z","status":"running"}},{"cursor":"nPvoDMxI6tFxM2JyamxoczczY2x2ZWxn","job":{"createdAt":"2026-11-14T05:09:33.444991Z","finishedAt":"2026-11-14T05:09:41Z","id":"job-dbruq3brjlhs73clvelg","planId":"plan-srv-006","serviceId":"srv-dbrupgm1egvs73cbq8m0","startCommand":"echo hello from a one-off job && sleep 5","startedAt":"2026-11-14T05:09:33Z","status":"succeeded"}}]
        """#
        let (client, _) = RenderClient.routed { _ in (200, live) }
        let store = JobsStore(client: client, serviceID: "srv-dbrupgm1egvs73cbq8m0", pollInterval: .seconds(60))

        await store.refresh()
        store.stopPolling()

        #expect(store.errorMessage == nil)
        #expect(store.jobs.map(\.status) == [.failed, .running, .succeeded])
        let running = try #require(store.jobs.dropFirst().first)
        #expect(running.finishedAt == nil && running.duration == nil)
        let succeeded = try #require(store.jobs.last)
        #expect(succeeded.duration == 8)
    }

    @Test("a running job is polled until it settles, then polling stops")
    func pollsUntilSettled() async throws {
        let (client, transport) = RenderClient.routed { path in
            path.hasSuffix("/jobs/job-1")
                ? (200, job(id: "job-1", status: "succeeded", finishedAt: "2026-11-14T10:02:00Z"))
                : (200, page([job(id: "job-1", status: "running")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pollInterval: .milliseconds(20))

        await store.refresh()
        for _ in 0..<100 where store.job(id: "job-1")?.status != .succeeded {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.job(id: "job-1")?.status == .succeeded)

        // Settled: no more reads after a few more intervals.
        let reads = transport.requests.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(transport.requests.count == reads)
    }

    @Test("a settled list never starts polling")
    func settledListDoesNotPoll() async throws {
        let (client, transport) = RenderClient.routed { _ in
            (200, page([job(id: "job-1", status: "failed")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pollInterval: .milliseconds(10))

        await store.refresh()
        try await Task.sleep(for: .milliseconds(80))

        #expect(transport.requests.count == 1)
    }

    @Test("an unknown status counts as settled, so it can't poll forever")
    func unknownStatusIsSettled() {
        let summary = JobSummary(
            id: "job-1", startCommand: "x", planID: "p", status: "something_new",
            createdAt: .now, startedAt: nil, finishedAt: nil
        )
        #expect(summary.status == nil)
        #expect(!summary.isActive)
    }

    @Test("static sites don't offer jobs")
    func staticSitesHaveNoJobs() {
        #expect(!Components.Schemas.ServiceType.staticSite.supportsJobs)
        #expect(Components.Schemas.ServiceType.webService.supportsJobs)
        #expect(Components.Schemas.ServiceType.cronJob.supportsJobs)
    }

    // MARK: - Review fixes (PR #58)

    @Test("a page requested before a refresh is thrown away, not appended to the new list")
    func stalePageIsDiscarded() async {
        let gate = Gate()
        let (client, _) = Self.held(gate) { path in
            path.contains("cursor=")
                ? (200, page([job(id: "job-old", status: "succeeded")]))
                : (200, page([job(id: "job-1", status: "succeeded")]))
        } holding: { $0.contains("cursor=") }
        let store = JobsStore(client: client, serviceID: "srv-1", pageSize: 1)
        await store.refresh()
        #expect(store.hasMore)

        let paging = Task { await store.loadNextPage() }
        await gate.waitUntilHeld()
        await store.refresh()
        await gate.release()
        await paging.value

        #expect(store.jobs.map(\.id) == ["job-1"])
        #expect(!store.isLoading)
    }

    @Test("a running job on a later page starts polling")
    func laterPageStartsPolling() async throws {
        let (client, _) = RenderClient.routed { path in
            if path.hasSuffix("/jobs/job-old") {
                return (200, job(id: "job-old", status: "succeeded", finishedAt: "2026-11-14T10:02:00Z"))
            }
            return path.contains("cursor=")
                ? (200, page([job(id: "job-old", status: "running")]))
                : (200, page([job(id: "job-1", status: "succeeded")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pageSize: 1, pollInterval: .milliseconds(20))
        await store.refresh()
        await store.loadNextPage()

        for _ in 0..<100 where store.job(id: "job-old")?.status != .succeeded {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.job(id: "job-old")?.status == .succeeded)
        store.stopPolling()
    }

    @Test("a read sent before a cancel can't move the canceled job back to running")
    func staleReadDoesNotRegress() async {
        let gate = Gate()
        let (client, _) = Self.held(gate) { path in
            if path.hasSuffix("/cancel") {
                return (200, job(id: "job-1", status: "canceled", finishedAt: "2026-11-14T10:02:00Z"))
            }
            return path.hasSuffix("/jobs/job-1")
                ? (200, job(id: "job-1", status: "running"))
                : (200, page([job(id: "job-1", status: "running")]))
        } holding: { $0.hasSuffix("/jobs/job-1") }
        let store = JobsStore(client: client, serviceID: "srv-1", pollInterval: .seconds(60))
        await store.refresh()

        let reading = Task { await store.reread(jobID: "job-1") }
        await gate.waitUntilHeld()
        await store.cancel(jobID: "job-1")
        await gate.release()
        await reading.value

        #expect(store.job(id: "job-1")?.status == .canceled)
        store.stopPolling()
    }

    @Test("a list holding a status the app doesn't know still loads, and that job counts as settled")
    func unknownStatusDecodes() async {
        let (client, transport) = RenderClient.routed { _ in
            (200, page([job(id: "job-2", status: "something_new"), job(id: "job-1", status: "succeeded")]))
        }
        let store = JobsStore(client: client, serviceID: "srv-1", pollInterval: .milliseconds(10))

        await store.refresh()

        #expect(store.errorMessage == nil)
        #expect(store.jobs.map(\.id) == ["job-2", "job-1"])
        #expect(store.jobs.first?.status == nil)
        #expect(transport.requests.count == 1)
    }

    /// A client that holds the first request matching `holding` until the test releases it.
    private static func held(
        _ gate: Gate,
        route: @escaping @Sendable (String) -> (status: Int, body: String),
        holding: @escaping @Sendable (String) -> Bool
    ) -> (RenderClient, StubTransport) {
        let transport = StubTransport { request, _, _ in
            let path = request.path ?? ""
            if holding(path) { await gate.holdIfFirst() }
            let answer = route(path)
            var response = HTTPResponse(status: .init(code: answer.status))
            response.headerFields = [.contentType: "application/json"]
            return (response, HTTPBody(answer.body))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        return (client, transport)
    }
}

/// Holds one request until released, and lets the test wait until it's being held.
private actor Gate {
    private var claimed = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private var released = false

    func holdIfFirst() async {
        guard !claimed else { return }
        claimed = true
        heldWaiter?.resume()
        heldWaiter = nil
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilHeld() async {
        if claimed { return }
        await withCheckedContinuation { heldWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
