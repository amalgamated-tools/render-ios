import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Maintenance runs: decoding, names, ordering, and the two writes.
@MainActor
@Suite("Maintenance")
struct MaintenanceStoreTests {
    /// Render's answers, changeable mid-test, plus the requests the store sent.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: (Int, String) = (200, "[]")
        private var _write: (Int, String) = (202, "")
        private var _writes: [(method: HTTPRequest.Method, path: String, body: [String: Any])] = []

        var list: (Int, String) { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
        var write: (Int, String) { get { lock.withLock { _write } } set { lock.withLock { _write = newValue } } }
        var writes: [(method: HTTPRequest.Method, path: String, body: [String: Any])] {
            get { lock.withLock { _writes } }
            set { lock.withLock { _writes = newValue } }
        }
    }

    private nonisolated static func runJSON(
        id: String, resource: String, state: String, at: String = "2026-12-01T10:00:00Z", by: String? = "2026-12-08T10:00:00Z"
    ) -> String {
        let pending = by.map { #","pendingMaintenanceBy":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","type":"database_upgrade","scheduledAt":"\#(at)"\#(pending),"state":"\#(state)","resourceId":"\#(resource)"}"#
    }

    private func store(_ backend: Backend) -> (MaintenanceStore, StubTransport) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            let answer: (Int, String)
            if request.method == .post || request.method == .patch {
                var data = Data()
                if let body { data = try await Data(collecting: body, upTo: 8192) }
                let sent = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                backend.writes.append((request.method, path, sent))
                answer = backend.write
            } else if path.hasPrefix("/services/srv-") {
                answer = (200, Fixtures.serviceJSON(id: "srv-web", type: "web_service", details: Fixtures.serviceDetailsJSON(for: "web_service"))
                    .replacingOccurrences(of: #""name":"api""#, with: #""name":"web""#))
            } else if path.hasPrefix("/postgres/") {
                answer = (404, #"{"message":"not found"}"#)
            } else {
                answer = backend.list
            }
            var response = HTTPResponse(status: .init(code: answer.0))
            response.headerFields = [.contentType: "application/json"]
            return (response, answer.1.isEmpty ? nil : HTTPBody(answer.1))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        return (MaintenanceStore(client: client, ownerID: "tea-1", now: { Self.date("2026-11-20T00:00:00Z") }), transport)
    }

    private nonisolated static func date(_ iso: String) -> Date {
        try! Date(iso, strategy: .iso8601)
    }

    // MARK: - Loading

    @Test("the list decodes an unknown state, puts upcoming runs first, and falls back to the ID")
    func loadOrdersAndNames() async throws {
        let backend = Backend()
        backend.list = (200, "[" + [
            Self.runJSON(id: "mrn-done", resource: "srv-web", state: "succeeded", at: "2026-11-01T10:00:00Z"),
            Self.runJSON(id: "mrn-late", resource: "dpg-gone", state: "scheduled", at: "2026-12-05T10:00:00Z", by: nil),
            Self.runJSON(id: "mrn-soon", resource: "srv-web", state: "scheduled", at: "2026-12-01T10:00:00Z"),
            Self.runJSON(id: "mrn-new", resource: "srv-web", state: "paused_for_review", at: "2026-12-03T10:00:00Z"),
        ].joined(separator: ",") + "]")
        let (store, transport) = store(backend)

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.upcoming.map(\.id) == ["mrn-soon", "mrn-new", "mrn-late"])
        #expect(store.finished.map(\.id) == ["mrn-done"])
        #expect(store.run(id: "mrn-new")?.state == .other("paused_for_review"))
        #expect(store.run(id: "mrn-new")?.state.title == "Paused For Review")
        #expect(store.run(id: "mrn-soon")?.displayName == "web")
        #expect(store.run(id: "mrn-late")?.displayName == "dpg-gone")
        #expect(store.run(id: "mrn-late")?.pendingMaintenanceBy == nil)
        #expect(transport.requests.first?.path?.contains("ownerId=tea-1") == true)
        // One lookup per resource, not per run.
        #expect(transport.requests.filter { $0.path?.hasPrefix("/services/") == true }.count == 1)
    }

    @Test("a failed list shows an error and keeps loading finished")
    func loadFailure() async {
        let backend = Backend()
        backend.list = (400, #"{"message":"invalid state"}"#)
        let (store, _) = store(backend)

        await store.load()

        #expect(store.hasLoaded)
        #expect(store.errorMessage != nil)
        #expect(store.runs.isEmpty)
    }

    // MARK: - Writes

    @Test("rescheduling sends the new time and moves the run")
    func reschedule() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled") + "]")
        let (store, _) = store(backend)
        await store.load()
        let run = try #require(store.run(id: "mrn-1"))
        let newDate = Self.date("2026-12-04T09:30:00Z")

        let ok = await store.reschedule(run, to: newDate)

        #expect(ok)
        #expect(backend.writes.count == 1)
        #expect(backend.writes[0].method == .patch)
        #expect(backend.writes[0].path == "/maintenance/mrn-1")
        // The client sends fractional seconds, so compare the instant rather than the text.
        let sent = try #require(backend.writes[0].body["scheduledAt"] as? String)
        #expect(try Date(sent, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)) == newDate)
        #expect(store.run(id: "mrn-1")?.scheduledAt == newDate)
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("a time past the deadline is refused without asking Render")
    func reschedulePastDeadline() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled") + "]")
        let (store, _) = store(backend)
        await store.load()
        let run = try #require(store.run(id: "mrn-1"))

        let ok = await store.reschedule(run, to: Self.date("2026-12-09T10:00:00Z"))

        #expect(!ok)
        #expect(backend.writes.isEmpty)
        #expect(store.actionResult?.isFailure == true)

        // The request must be *before* the deadline, so the deadline itself is refused too.
        #expect(!(await store.reschedule(run, to: Self.date("2026-12-08T10:00:00Z"))))
        #expect(backend.writes.isEmpty)
    }

    @Test("a time that has already passed is refused without asking Render")
    func reschedulePastTime() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled") + "]")
        let (store, _) = store(backend)
        await store.load()
        let run = try #require(store.run(id: "mrn-1"))

        #expect(!(await store.reschedule(run, to: Self.date("2026-11-19T23:59:00Z"))))
        #expect(backend.writes.isEmpty)
        #expect(store.actionResult?.message == "Choose a time in the future.")
    }

    @Test("an action uses the run as the list shows it now, not the copy the sheet was opened with")
    func actsOnCurrentRun() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled") + "]")
        let (store, _) = store(backend)
        await store.load()
        let stale = try #require(store.run(id: "mrn-1"))

        // A refresh while the sheet is open: the run has started, and its deadline moved earlier.
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "in_progress") + "]")
        await store.load()
        #expect(!(await store.trigger(stale)))
        #expect(store.actionResult?.isFailure == true)
        store.dismissActionResult()
        #expect(!(await store.reschedule(stale, to: Self.date("2026-12-02T10:00:00Z"))))
        // A fresh failure, so the sheet never shows an earlier message as this one.
        #expect(store.actionResult?.message == "This maintenance run is no longer scheduled.")
        #expect(store.actionResult?.isFailure == true)

        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled", by: "2026-12-02T00:00:00Z") + "]")
        await store.load()
        #expect(!(await store.reschedule(stale, to: Self.date("2026-12-04T10:00:00Z"))))
        #expect(backend.writes.isEmpty)
    }

    @Test("running now marks the run in progress, and any 2xx counts")
    func trigger() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled") + "]")
        backend.write = (200, "")
        let (store, _) = store(backend)
        await store.load()
        let run = try #require(store.run(id: "mrn-1"))

        let ok = await store.trigger(run)

        #expect(ok)
        #expect(backend.writes.map(\.path) == ["/maintenance/mrn-1/trigger"])
        #expect(store.run(id: "mrn-1")?.state == .inProgress)
    }

    @Test("a refused write leaves the run as it was")
    func writeFailure() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "scheduled") + "]")
        backend.write = (404, #"{"message":"not found"}"#)
        let (store, _) = store(backend)
        await store.load()
        let run = try #require(store.run(id: "mrn-1"))

        let ok = await store.trigger(run)

        #expect(!ok)
        #expect(store.run(id: "mrn-1")?.state == .scheduled)
        #expect(store.actionResult?.isFailure == true)
        #expect(!store.isSaving)
    }

    @Test("a run that isn't scheduled can't be moved or started")
    func onlyScheduledRunsAct() async throws {
        let backend = Backend()
        backend.list = (200, "[" + Self.runJSON(id: "mrn-1", resource: "srv-web", state: "in_progress") + "]")
        let (store, _) = store(backend)
        await store.load()
        let run = try #require(store.run(id: "mrn-1"))

        #expect(!(await store.trigger(run)))
        #expect(!(await store.reschedule(run, to: Self.date("2026-12-02T10:00:00Z"))))
        #expect(backend.writes.isEmpty)
    }
}
