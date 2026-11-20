import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// The organization audit log: saving the organization ID and Audit Log API key, and reading the log
/// with that key rather than the sign-in one.
@MainActor
@Suite("Organization audit log")
struct OrgAuditLogTests {
    private final class MemoryStore: OrgAuditLogCredentialStoring, @unchecked Sendable {
        struct Refused: Error {}
        private let lock = NSLock()
        private var _value: OrgAuditLogCredential?
        private var _failsDelete = false
        var value: OrgAuditLogCredential? { get { lock.withLock { _value } } set { lock.withLock { _value = newValue } } }
        var failsDelete: Bool { get { lock.withLock { _failsDelete } } set { lock.withLock { _failsDelete = newValue } } }
        init(_ value: OrgAuditLogCredential? = nil) { _value = value }
        func read() throws -> OrgAuditLogCredential? { value }
        func write(_ credential: OrgAuditLogCredential?) throws {
            if credential == nil, failsDelete { throw Refused() }
            value = credential
        }
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

    /// What Render answers, and the path and key of each request it got.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _answer: (Int, String) = (200, "[]")
        private var _requests: [(path: String, key: String?)] = []
        private var _gate: Gate?
        var gate: Gate? { get { lock.withLock { _gate } } set { lock.withLock { _gate = newValue } } }
        var answer: (Int, String) { get { lock.withLock { _answer } } set { lock.withLock { _answer = newValue } } }
        var requests: [(path: String, key: String?)] { lock.withLock { _requests } }
        func record(_ path: String, _ key: String?) { lock.withLock { _requests.append((path, key)) } }
    }

    private nonisolated static func auditJSON(_ id: String, event: String) -> String {
        #"{"cursor":"c-\#(id)","auditLog":{"id":"\#(id)","timestamp":"2026-11-20T03:56:39.098547Z","event":"\#(event)","status":"success","actor":{"type":"user","email":"a@example.com","id":"usr-a"},"metadata":{"workspace_id":"tea-1"}}}"#
    }

    private func settings(_ backend: Backend, store: MemoryStore = MemoryStore()) -> OrgAuditLogSettings {
        OrgAuditLogSettings(store: store) { key in
            let transport = StubTransport { request, _, _ in
                backend.record(request.path ?? "", request.headerFields[.authorization])
                let answer = backend.answer
                if let gate = backend.gate { await gate.hold() }
                var response = HTTPResponse(status: .init(code: answer.0))
                response.headerFields = [.contentType: "application/json"]
                return (response, HTTPBody(answer.1))
            }
            return RenderClient(apiKeyProvider: StaticAPIKeyProvider(key), retryPolicy: .none, transport: transport)
        }
    }

    @Test("a pair Render accepts is saved, and the log is read from the organization with that key")
    func savesAndReads() async throws {
        let backend = Backend()
        let store = MemoryStore()
        let settings = settings(backend, store: store)
        #expect(settings.makeLogStore() == nil)

        let saved = await settings.save(organizationID: "  org-abc ", apiKey: " rnd_audit\n")
        #expect(saved)
        #expect(store.value == OrgAuditLogCredential(organizationID: "org-abc", apiKey: "rnd_audit"))
        #expect(backend.requests.first?.path.hasPrefix("/organizations/org-abc/audit-logs?") == true)
        #expect(backend.requests.first?.key == "Bearer rnd_audit")

        backend.answer = (200, "[" + Self.auditJSON("aud-1", event: "InviteToOrgEvent") + "]")
        let log = try #require(settings.makeLogStore())
        await log.load()
        #expect(log.errorMessage == nil)
        #expect(log.entries.map(\.title) == ["Invite to org"])
        #expect(backend.requests.last?.key == "Bearer rnd_audit")
    }

    @Test("a key Render refuses is not saved, and the message says the key doesn't cover the organization")
    func forbiddenNotSaved() async {
        let backend = Backend()
        backend.answer = (403, #"{"message":"forbidden"}"#)
        let store = MemoryStore()
        let settings = settings(backend, store: store)

        let saved = await settings.save(organizationID: "org-other", apiKey: "rnd_audit")
        #expect(!saved)
        #expect(store.value == nil)
        #expect(settings.credential == nil)
        #expect(settings.errorMessage?.contains("only covers the organization it was created in") == true)
    }

    @Test("an unknown organization and a revoked key each get their own message")
    func notFoundAndUnauthorized() async {
        let backend = Backend()
        let settings = settings(backend)

        backend.answer = (404, #"{"message":"not found"}"#)
        #expect(!(await settings.save(organizationID: "org-missing", apiKey: "k")))
        #expect(settings.errorMessage == "Render doesn't know an organization with the ID org-missing.")

        backend.answer = (401, #"{"message":"unauthorized"}"#)
        #expect(!(await settings.save(organizationID: "org-abc", apiKey: "k")))
        #expect(settings.errorMessage?.contains("didn't accept this Audit Log API key") == true)
    }

    @Test("an ID that isn't an organization's is refused without asking Render")
    func rejectsNonOrgID() async {
        let backend = Backend()
        let settings = settings(backend)
        #expect(!(await settings.save(organizationID: "tea-123", apiKey: "k")))
        #expect(!(await settings.save(organizationID: "org-abc", apiKey: "  ")))
        #expect(backend.requests.isEmpty)
    }

    @Test("a failed change keeps the saved pair, and removing deletes it")
    func failedChangeKeepsOld() async {
        let backend = Backend()
        let original = OrgAuditLogCredential(organizationID: "org-abc", apiKey: "old")
        let store = MemoryStore(original)
        let settings = settings(backend, store: store)
        #expect(settings.credential == original)

        backend.answer = (403, #"{"message":"forbidden"}"#)
        #expect(!(await settings.save(organizationID: "org-xyz", apiKey: "new")))
        #expect(settings.credential == original)
        #expect(store.value == original)

        settings.remove()
        #expect(settings.credential == nil)
        #expect(store.value == nil)
        #expect(settings.makeLogStore() == nil)
    }

    @Test("if the Keychain won't delete the pair, it stays and the error says so")
    func failedRemovalKeepsPair() {
        let original = OrgAuditLogCredential(organizationID: "org-abc", apiKey: "old")
        let store = MemoryStore(original)
        store.failsDelete = true
        let settings = settings(Backend(), store: store)

        #expect(!settings.remove())
        #expect(settings.credential == original)
        #expect(store.value == original)
        #expect(settings.errorMessage?.contains("couldn't be removed") == true)

        store.failsDelete = false
        #expect(settings.remove())
        #expect(settings.credential == nil)
        #expect(settings.errorMessage == nil)
    }

    @Test("cancelling while a new pair is being checked keeps the saved one, even if Render then accepts it")
    func cancelDuringCheck() async {
        let backend = Backend()
        let gate = Gate()
        backend.gate = gate
        let original = OrgAuditLogCredential(organizationID: "org-abc", apiKey: "old")
        let store = MemoryStore(original)
        let settings = settings(backend, store: store)

        let save = Task { await settings.save(organizationID: "org-xyz", apiKey: "new") }
        await gate.waitUntilEntered()
        #expect(settings.isVerifying)
        settings.cancelSave()
        #expect(!settings.isVerifying)
        await gate.open()

        #expect(!(await save.value))
        #expect(settings.credential == original)
        #expect(store.value == original)
        #expect(settings.errorMessage == nil)
    }

    @Test("removing the key while a new pair is being checked keeps it removed")
    func removeDuringCheck() async {
        let backend = Backend()
        let gate = Gate()
        backend.gate = gate
        let store = MemoryStore(OrgAuditLogCredential(organizationID: "org-abc", apiKey: "old"))
        let settings = settings(backend, store: store)

        let save = Task { await settings.save(organizationID: "org-xyz", apiKey: "new") }
        await gate.waitUntilEntered()
        #expect(settings.remove())
        await gate.open()

        #expect(!(await save.value))
        #expect(settings.credential == nil)
        #expect(store.value == nil)
    }

    @Test("a workspace log's 403 keeps the general message")
    func workspaceMessageUnchanged() {
        let error = RenderError.forbidden(message: "forbidden")
        #expect(AuditLogStore.describe(error, scope: .workspace(ownerID: "tea-1")) == error.errorDescription)
    }
}
