import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Per-service overrides of the workspace's Render notification settings: the one-service screen and
/// the workspace's list of overridden services.
@MainActor
@Suite("Service notification overrides")
struct ServiceNotificationOverridesTests {
    /// What Render answers, changeable mid-test, plus the PATCH bodies the store sent.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _override: (Int, String) = (200, Backend.overrideJSON(send: "default", preview: "default"))
        private var _patch: (Int, String)?
        private var _patchBodies: [[String: String]] = []
        private var _list: (Int, String) = (200, "[]")
        /// Service names by ID. A missing ID answers 404, as for a deleted service.
        private var _names: [String: String] = [:]
        /// Answers a list request that carries this cursor, for a second page.
        private var _nextPage: (cursor: String, answer: (Int, String))?
        private var _overrideGate: Gate?

        var nextPage: (cursor: String, answer: (Int, String))? {
            get { lock.withLock { _nextPage } }
            set { lock.withLock { _nextPage = newValue } }
        }

        /// Holds the next override read, after it has taken its answer, until the gate opens.
        func holdNextOverrideRead(at gate: Gate) {
            lock.withLock { _overrideGate = gate }
        }

        func takeOverrideGate() -> Gate? {
            lock.withLock {
                defer { _overrideGate = nil }
                return _overrideGate
            }
        }

        nonisolated static func overrideJSON(id: String = "srv-1", send: String, preview: String) -> String {
            #"{"serviceId":"\#(id)","notificationsToSend":"\#(send)","previewNotificationsEnabled":"\#(preview)"}"#
        }

        var override: (Int, String) {
            get { lock.withLock { _override } }
            set { lock.withLock { _override = newValue } }
        }

        /// When nil, a PATCH answers by applying its body to `override`, as Render does.
        var patch: (Int, String)? {
            get { lock.withLock { _patch } }
            set { lock.withLock { _patch = newValue } }
        }

        var patchBodies: [[String: String]] {
            get { lock.withLock { _patchBodies } }
            set { lock.withLock { _patchBodies = newValue } }
        }

        var list: (Int, String) {
            get { lock.withLock { _list } }
            set { lock.withLock { _list = newValue } }
        }

        var names: [String: String] {
            get { lock.withLock { _names } }
            set { lock.withLock { _names = newValue } }
        }
    }

    private func client(_ backend: Backend) -> (RenderClient, StubTransport) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            var answer: (Int, String)
            if path.hasPrefix("/notification-settings/owners/") {
                answer = (200, #"{"ownerId":"tea-1","slackEnabled":false,"emailEnabled":true,"previewNotificationsEnabled":false,"notificationsToSend":"failure"}"#)
            } else if path.hasPrefix("/notification-settings/overrides/services/"), request.method == .patch {
                var data = Data()
                if let body { data = try await Data(collecting: body, upTo: 4096) }
                let sent = (try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:]
                backend.patchBodies.append(sent)
                if let fixed = backend.patch {
                    answer = fixed
                } else {
                    let current = (try? JSONSerialization.jsonObject(with: Data(backend.override.1.utf8)) as? [String: String]) ?? [:]
                    let merged = current.merging(sent) { $1 }
                    answer = (200, Backend.overrideJSON(
                        send: merged["notificationsToSend"] ?? "default",
                        preview: merged["previewNotificationsEnabled"] ?? "default"
                    ))
                    backend.override = answer
                }
            } else if path.hasPrefix("/notification-settings/overrides/services/") {
                answer = backend.override
                if let gate = backend.takeOverrideGate() { await gate.hold() }
            } else if path.hasPrefix("/notification-settings/overrides") {
                if let next = backend.nextPage, path.contains("cursor=\(next.cursor)") {
                    answer = next.answer
                } else {
                    answer = backend.list
                }
            } else if path.hasPrefix("/services/") {
                let id = String(path.dropFirst("/services/".count))
                answer = backend.names[id].map {
                    (200, Fixtures.serviceJSON(id: id, type: "web_service", details: Fixtures.serviceDetailsJSON(for: "web_service"))
                        .replacingOccurrences(of: #""name":"api""#, with: #""name":"\#($0)""#))
                } ?? (404, #"{"message":"not found"}"#)
            } else {
                answer = (404, #"{"message":"not found"}"#)
            }
            var response = HTTPResponse(status: .init(code: answer.0))
            response.headerFields = [.contentType: "application/json"]
            return (response, HTTPBody(answer.1))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        return (client, transport)
    }

    /// Lets a test hold a request in flight and know when it got there.
    private actor Gate {
        private var entered = false
        private var isOpen = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiter: CheckedContinuation<Void, Never>?

        func hold() async {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters = []
            guard !isOpen else { return }
            await withCheckedContinuation { openWaiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func open() {
            isOpen = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    private func store(_ backend: Backend) -> (ServiceNotificationOverridesStore, StubTransport) {
        let (client, transport) = client(backend)
        return (ServiceNotificationOverridesStore(client: client, ownerID: "tea-1", serviceID: "srv-1"), transport)
    }

    // MARK: - Mapping

    @Test("Render's strings map both ways, and an unknown one reads as the workspace default")
    func rawMapping() {
        #expect(ServiceNotificationOverrides.Level(raw: "default") == .workspaceDefault)
        #expect(ServiceNotificationOverrides.Level(raw: "failure") == .level(.failure))
        #expect(ServiceNotificationOverrides.Level(raw: "something_new") == .workspaceDefault)
        #expect(ServiceNotificationOverrides.Level.allCases.map(\.raw) == ["default", "none", "failure", "all"])
        #expect(ServiceNotificationOverrides.Preview(raw: "true") == .on)
        #expect(ServiceNotificationOverrides.Preview(raw: "false") == .off)
        #expect(ServiceNotificationOverrides.Preview(raw: "default") == .workspaceDefault)
        #expect(ServiceNotificationOverrides.Preview.allCases.map(\.raw) == ["default", "true", "false"])
    }

    @Test("the effective setting falls back to the workspace's only where the service doesn't override")
    func effectiveSettings() {
        let workspace = OwnerNotificationSettings(
            notificationsToSend: .failure, emailEnabled: true, previewNotificationsEnabled: false, slackEnabled: false
        )
        let followsWorkspace = ServiceNotificationOverrides(notificationsToSend: .workspaceDefault, previewNotifications: .workspaceDefault)
        #expect(!followsWorkspace.isOverridden)
        #expect(followsWorkspace.effectiveLevel(workspace: workspace) == .failure)
        #expect(!followsWorkspace.effectivePreview(workspace: workspace))

        let own = ServiceNotificationOverrides(notificationsToSend: .level(.all), previewNotifications: .on)
        #expect(own.isOverridden)
        #expect(own.effectiveLevel(workspace: workspace) == .all)
        #expect(own.effectivePreview(workspace: workspace))
    }

    // MARK: - One service

    @Test("load reads the service's overrides and the workspace settings they override")
    func loadsBoth() async {
        let backend = Backend()
        backend.override = (200, Backend.overrideJSON(send: "all", preview: "default"))
        let (store, _) = store(backend)

        await store.load()

        #expect(store.overrides == .init(notificationsToSend: .level(.all), previewNotifications: .workspaceDefault))
        #expect(store.workspace?.notificationsToSend == .failure)
        #expect(store.errorMessage == nil)
    }

    @Test("an edit sends only the field that changed, and takes Render's reply")
    func patchSendsOnlyChange() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()

        await store.update { $0.notificationsToSend = .level(.failure) }
        #expect(backend.patchBodies.last == ["notificationsToSend": "failure"])

        await store.update { $0.previewNotifications = .on }
        #expect(backend.patchBodies.last == ["previewNotificationsEnabled": "true"])
        #expect(store.overrides == .init(notificationsToSend: .level(.failure), previewNotifications: .on))
    }

    @Test("an unchanged edit sends nothing")
    func unchangedEditIsNotSent() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()

        await store.update { $0.notificationsToSend = .workspaceDefault }

        #expect(backend.patchBodies.isEmpty)
    }

    @Test("a refused edit is rolled back, with Render's reason")
    func refusedEditRollsBack() async {
        let backend = Backend()
        // Render's answer, live, to a value it doesn't accept.
        backend.patch = (400, #"{"message":"invalid notification override (bogus)"}"#)
        let (store, _) = store(backend)
        await store.load()

        await store.update { $0.notificationsToSend = .level(.none) }

        #expect(store.overrides?.notificationsToSend == .workspaceDefault)
        #expect(store.errorMessage == "Invalid notification override (bogus).")
    }

    @Test("using workspace settings sets both fields back to default")
    func resetSendsBothDefaults() async {
        let backend = Backend()
        backend.override = (200, Backend.overrideJSON(send: "none", preview: "true"))
        let (store, _) = store(backend)
        await store.load()

        await store.resetToWorkspaceDefaults()

        #expect(backend.patchBodies.last == ["notificationsToSend": "default", "previewNotificationsEnabled": "default"])
        #expect(store.overrides?.isOverridden == false)
    }

    @Test("a read that started before a save can't replace what the save stored")
    func staleReadIgnoredAfterSave() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()

        // The read leaves while the service still follows the workspace, and is held there.
        let gate = Gate()
        backend.holdNextOverrideRead(at: gate)
        let refresh = Task { await store.load() }
        await gate.waitUntilEntered()

        await store.update { $0.notificationsToSend = .level(.all) }
        #expect(store.overrides?.notificationsToSend == .level(.all))

        await gate.open()
        await refresh.value
        #expect(store.overrides?.notificationsToSend == .level(.all), "the older read must not win")
    }

    // MARK: - Workspace list

    @Test("the workspace list names each overridden service, sorted, and keeps one that can't be read")
    func workspaceListNamesServices() async throws {
        let backend = Backend()
        backend.list = (200, """
            [{"cursor":"c1","override":\(Backend.overrideJSON(id: "srv-b", send: "all", preview: "default"))},
             {"cursor":"c2","override":\(Backend.overrideJSON(id: "srv-a", send: "default", preview: "false"))},
             {"cursor":"c3","override":\(Backend.overrideJSON(id: "srv-gone", send: "none", preview: "default"))},
             {"cursor":"c4","override":\(Backend.overrideJSON(id: "srv-plain", send: "default", preview: "default"))}]
            """)
        backend.names = ["srv-a": "api", "srv-b": "worker"]
        let (client, transport) = client(backend)
        let store = NotificationSettingsStore(client: client, ownerID: "tea-1")

        await store.loadOverrides()

        let services = try #require(store.overriddenServices)
        // "srv-plain" follows the workspace in both fields, so it isn't listed.
        #expect(services.map(\.id) == ["srv-a", "srv-gone", "srv-b"])
        #expect(services.map(\.name) == ["api", nil, "worker"])
        #expect(services[0].overrides.previewNotifications == .off)
        let listQuery = try #require(transport.requests.compactMap(\.path).first { $0.hasPrefix("/notification-settings/overrides?") })
        #expect(listQuery.contains("ownerId=tea-1"))
    }

    @Test("the list loads a page at a time, and Show More appends the next page")
    func workspaceListPages() async throws {
        let backend = Backend()
        backend.list = (200, """
            [{"cursor":"c1","override":\(Backend.overrideJSON(id: "srv-a", send: "all", preview: "default"))},
             {"cursor":"c2","override":\(Backend.overrideJSON(id: "srv-b", send: "none", preview: "default"))}]
            """)
        backend.nextPage = (cursor: "c2", answer: (200, """
            [{"cursor":"c3","override":\(Backend.overrideJSON(id: "srv-c", send: "failure", preview: "default"))}]
            """))
        backend.names = ["srv-a": "api", "srv-b": "billing", "srv-c": "cron"]
        let (client, _) = client(backend)
        let store = NotificationSettingsStore(client: client, ownerID: "tea-1", overridesPageSize: 2)

        await store.loadOverrides()
        #expect(store.overriddenServices?.map(\.id) == ["srv-a", "srv-b"])
        #expect(store.hasMoreOverrides)

        await store.loadMoreOverrides()
        #expect(store.overriddenServices?.map(\.id) == ["srv-a", "srv-b", "srv-c"])
        #expect(!store.hasMoreOverrides, "a short page is the last")
    }

    @Test("a failed refresh keeps the earlier list and reports the error with it")
    func workspaceRefreshFailureKeepsList() async {
        let backend = Backend()
        backend.list = (200, #"[{"cursor":"c1","override":\#(Backend.overrideJSON(id: "srv-a", send: "all", preview: "default"))}]"#)
        backend.names = ["srv-a": "api"]
        let (client, _) = client(backend)
        let store = NotificationSettingsStore(client: client, ownerID: "tea-1")
        await store.loadOverrides()

        backend.list = (500, #"{"message":"boom"}"#)
        await store.loadOverrides()

        #expect(store.overriddenServices?.map(\.id) == ["srv-a"])
        #expect(store.overridesErrorMessage != nil)
    }

    @Test("a list failure is reported without a list")
    func workspaceListFailure() async {
        let backend = Backend()
        backend.list = (500, #"{"message":"boom"}"#)
        let (client, _) = client(backend)
        let store = NotificationSettingsStore(client: client, ownerID: "tea-1")

        await store.loadOverrides()

        #expect(store.overriddenServices == nil)
        #expect(store.overridesErrorMessage != nil)
    }
}
