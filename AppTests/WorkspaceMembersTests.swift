import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// The workspace screen: details, members (role changes and removal) and the audit log.
@MainActor
@Suite("Workspace members and audit log")
struct WorkspaceMembersTests {
    private static let me = "usr-me"

    /// Render's answers, changeable mid-test, plus the bodies the store sent.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _members: (Int, String) = (200, "[]")
        private var _patch: (Int, String) = (200, "{}")
        private var _delete: (Int, String) = (204, "")
        private var _audit: (Int, String) = (200, "[]")
        private var _nextAudit: (cursor: String, answer: (Int, String))?
        private var _bodies: [[String: Any]] = []
        private var _membersGate: Gate?

        var members: (Int, String) { get { lock.withLock { _members } } set { lock.withLock { _members = newValue } } }
        var patch: (Int, String) { get { lock.withLock { _patch } } set { lock.withLock { _patch = newValue } } }
        var delete: (Int, String) { get { lock.withLock { _delete } } set { lock.withLock { _delete = newValue } } }
        var audit: (Int, String) { get { lock.withLock { _audit } } set { lock.withLock { _audit = newValue } } }
        var nextAudit: (cursor: String, answer: (Int, String))? {
            get { lock.withLock { _nextAudit } }
            set { lock.withLock { _nextAudit = newValue } }
        }
        var bodies: [[String: Any]] { get { lock.withLock { _bodies } } set { lock.withLock { _bodies = newValue } } }
        func holdNextMembers(at gate: Gate) { lock.withLock { _membersGate = gate } }
        func takeMembersGate() -> Gate? { lock.withLock { defer { _membersGate = nil }; return _membersGate } }
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

    private nonisolated static func memberJSON(_ id: String, name: String, role: String, status: String = "active") -> String {
        #"{"userId":"\#(id)","name":"\#(name)","email":"\#(name.lowercased())@example.com","status":"\#(status)","role":"\#(role)","mfaEnabled":false}"#
    }

    private nonisolated static func auditJSON(_ id: String, event: String, status: String = "success", actor: String = #"{"type":"user","email":"a@example.com","id":"usr-a"}"#) -> String {
        #"{"cursor":"c-\#(id)","auditLog":{"id":"\#(id)","timestamp":"2026-11-17T03:56:39.098547Z","event":"\#(event)","status":"\#(status)","actor":\#(actor),"metadata":{"user_agent":"curl/8.7.1","service":"srv-1 (api)","source_ip":"203.0.113.7"}}}"#
    }

    private func client(_ backend: Backend) -> (RenderClient, StubTransport) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            var answer: (Int, String)
            if request.method == .patch {
                var data = Data()
                if let body { data = try await Data(collecting: body, upTo: 4096) }
                backend.bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:])
                answer = backend.patch
            } else if request.method == .delete {
                answer = backend.delete
            } else if path.contains("/audit-logs") {
                if let next = backend.nextAudit, path.contains("cursor=\(next.cursor)") {
                    answer = next.answer
                } else {
                    answer = backend.audit
                }
            } else if path.hasSuffix("/members") {
                answer = backend.members
                if let gate = backend.takeMembersGate() { await gate.hold() }
            } else {
                answer = (200, #"{"id":"tea-1","name":"acme","email":"team@example.com","type":"team"}"#)
            }
            var response = HTTPResponse(status: .init(code: answer.0))
            response.headerFields = [.contentType: "application/json"]
            return (response, answer.1.isEmpty ? nil : HTTPBody(answer.1))
        }
        return (RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport), transport)
    }

    private func store(_ backend: Backend) -> (WorkspaceMembersStore, StubTransport) {
        let (client, transport) = client(backend)
        return (WorkspaceMembersStore(client: client, ownerID: "tea-1"), transport)
    }

    // MARK: - Roles

    @Test("roles map from Render's uppercase values, and an unknown one keeps a readable name")
    func roleMapping() {
        #expect(MemberRole(raw: "ADMIN") == .admin)
        #expect(MemberRole(raw: "WORKSPACE_VIEWER") == .viewer)
        #expect(MemberRole(raw: "WORKSPACE_VIEWER").requestValue == .workspaceViewer)
        let future = MemberRole(raw: "WORKSPACE_AUDITOR")
        #expect(future == .other("WORKSPACE_AUDITOR"))
        #expect(future.displayName == "Auditor")
        #expect(future.requestValue == nil)
        #expect(MemberRole.assignable.compactMap(\.requestValue).count == MemberRole.assignable.count)
    }

    // MARK: - Loading

    @Test("load reads the workspace and its members, admins first, including a role this build doesn't know")
    func loadsWorkspaceAndMembers() async {
        let backend = Backend()
        backend.members = (200, "[" + [
            Self.memberJSON("usr-z", name: "Zed", role: "DEVELOPER"),
            Self.memberJSON("usr-b", name: "Bea", role: "WORKSPACE_AUDITOR", status: "inactive"),
            Self.memberJSON(Self.me, name: "Me", role: "ADMIN"),
        ].joined(separator: ",") + "]")
        let (store, _) = store(backend)

        await store.load()

        #expect(store.workspace?.name == "acme")
        #expect(store.workspace?.isTeam == true)
        #expect(store.members.map(\.userID) == [Self.me, "usr-b", "usr-z"])
        #expect(store.members[1].role == .other("WORKSPACE_AUDITOR"))
        #expect(!store.members[1].isActive)
        #expect(store.membersErrorMessage == nil)
    }

    @Test("the signed-in user can't manage themselves, and nobody can be managed before they're known")
    func cannotManageSelf() {
        let (store, _) = store(Backend())
        let me = WorkspaceMember(userID: Self.me, name: "Me", email: "me@example.com", role: .admin, isActive: true, isMFAEnabled: false)
        let other = WorkspaceMember(userID: "usr-z", name: "Zed", email: "zed@example.com", role: .developer, isActive: true, isMFAEnabled: false)
        #expect(!store.canManage(me, currentUserID: Self.me))
        #expect(store.canManage(other, currentUserID: Self.me))
        #expect(!store.canManage(other, currentUserID: nil))
    }

    // MARK: - Role changes

    @Test("changing a role sends Render's value and updates the row")
    func changeRole() async throws {
        let backend = Backend()
        backend.members = (200, "[" + Self.memberJSON("usr-z", name: "Zed", role: "DEVELOPER") + "]")
        backend.patch = (200, Self.memberJSON("usr-z", name: "Zed", role: "WORKSPACE_VIEWER"))
        let (store, transport) = store(backend)
        await store.load()
        let zed = try #require(store.members.first)

        let changed = await store.changeRole(of: zed, to: .viewer, currentUserID: Self.me)

        #expect(changed)
        #expect(backend.bodies.last?["role"] as? String == "WORKSPACE_VIEWER")
        #expect(transport.requests.contains { $0.method == .patch && ($0.path ?? "").hasSuffix("/owners/tea-1/members/usr-z") })
        #expect(store.members.first?.role == .viewer)
        #expect(store.actionResult?.message == "Zed is now Viewer.")
    }

    @Test("your own role, an unchanged role and an unknown role are never sent")
    func roleChangesNotSent() async throws {
        let backend = Backend()
        backend.members = (200, "[" + [
            Self.memberJSON(Self.me, name: "Me", role: "ADMIN"),
            Self.memberJSON("usr-z", name: "Zed", role: "DEVELOPER"),
        ].joined(separator: ",") + "]")
        let (store, _) = store(backend)
        await store.load()
        let me = try #require(store.members.first { $0.userID == Self.me })
        let zed = try #require(store.members.first { $0.userID == "usr-z" })

        #expect(!(await store.changeRole(of: me, to: .viewer, currentUserID: Self.me)))
        #expect(!(await store.changeRole(of: zed, to: .developer, currentUserID: Self.me)))
        #expect(!(await store.changeRole(of: zed, to: .other("WORKSPACE_AUDITOR"), currentUserID: Self.me)))
        #expect(backend.bodies.isEmpty)
    }

    @Test("a role change Render refuses shows its reason and keeps the role")
    func roleChangeRefused() async throws {
        let backend = Backend()
        backend.members = (200, "[" + Self.memberJSON("usr-z", name: "Zed", role: "DEVELOPER") + "]")
        // Render's live answer to a role it doesn't accept.
        backend.patch = (400, #"{"message":"invalid role"}"#)
        let (store, _) = store(backend)
        await store.load()
        let zed = try #require(store.members.first)

        let changed = await store.changeRole(of: zed, to: .admin, currentUserID: Self.me)

        #expect(!changed)
        #expect(store.actionResult?.message == "Invalid role.")
        #expect(store.members.first?.role == .developer)
    }

    // MARK: - Removal

    @Test("removing a member sends DELETE, accepts 204 or another 2xx, and drops the row", arguments: [204, 200])
    func removeMember(status: Int) async throws {
        let backend = Backend()
        backend.members = (200, "[" + Self.memberJSON("usr-z", name: "Zed", role: "DEVELOPER") + "]")
        backend.delete = (status, status == 200 ? "{}" : "")
        let (store, transport) = store(backend)
        await store.load()
        let zed = try #require(store.members.first)

        let removed = await store.remove(zed, currentUserID: Self.me)

        #expect(removed)
        #expect(transport.requests.contains { $0.method == .delete && ($0.path ?? "").hasSuffix("/owners/tea-1/members/usr-z") })
        #expect(store.members.isEmpty)
    }

    @Test("you can't remove yourself")
    func cannotRemoveSelf() async throws {
        let backend = Backend()
        backend.members = (200, "[" + Self.memberJSON(Self.me, name: "Me", role: "ADMIN") + "]")
        let (store, transport) = store(backend)
        await store.load()

        let removed = await store.remove(try #require(store.members.first), currentUserID: Self.me)

        #expect(!removed)
        #expect(!transport.requests.contains { $0.method == .delete })
    }

    @Test("a refresh from before a removal can't bring the member back")
    func staleRefreshAfterRemove() async throws {
        let backend = Backend()
        backend.members = (200, "[" + [
            Self.memberJSON(Self.me, name: "Me", role: "ADMIN"),
            Self.memberJSON("usr-z", name: "Zed", role: "DEVELOPER"),
        ].joined(separator: ",") + "]")
        let (store, _) = store(backend)
        await store.load()
        let zed = try #require(store.members.first { $0.userID == "usr-z" })

        let gate = Gate()
        backend.holdNextMembers(at: gate)
        let refresh = Task { await store.load() }
        await gate.waitUntilEntered()

        await store.remove(zed, currentUserID: Self.me)
        await gate.open()
        await refresh.value

        #expect(store.members.map(\.userID) == [Self.me], "the older list must not win")
    }

    // MARK: - Audit log

    @Test("event names read as words, keeping acronyms")
    func auditEventNames() {
        #expect(AuditLogEntry.displayName("CreateServerEvent") == "Create server")
        #expect(AuditLogEntry.displayName("ViewConnectionInfoEvent") == "View connection info")
        #expect(AuditLogEntry.displayName("ChangeOrg2FAEnforcementEvent") == "Change org 2FA enforcement")
        #expect(AuditLogEntry.displayName("SomethingBrandNewEvent") == "Something brand new")
        #expect(AuditLogEntry.displayName("Event") == "Event")
    }

    @Test("the audit log decodes an unknown event, a failure and an API key actor, a page at a time")
    func auditLog() async throws {
        let backend = Backend()
        backend.audit = (200, "[" + [
            Self.auditJSON("aud-1", event: "DeleteServerEvent"),
            Self.auditJSON("aud-2", event: "SomethingBrandNewEvent", status: "error", actor: #"{"type":"rest_api"}"#),
        ].joined(separator: ",") + "]")
        backend.nextAudit = (cursor: "c-aud-2", answer: (200, "[" + Self.auditJSON("aud-3", event: "CreateWebhookEvent", actor: #"{"type":"system"}"#) + "]"))
        let (client, _) = client(backend)
        let log = AuditLogStore(client: client, ownerID: "tea-1", pageSize: 2)

        await log.load()
        #expect(log.errorMessage == nil)
        #expect(log.entries.map(\.title) == ["Delete server", "Something brand new"])
        #expect(log.entries[0].actorDescription == "a@example.com")
        #expect(log.entries[0].metadata.map(\.key) == ["service", "source_ip", "user_agent"])
        #expect(!log.entries[1].succeeded)
        #expect(log.entries[1].actorDescription == "API key")
        #expect(log.hasMore)

        await log.loadMore()
        #expect(log.entries.map(\.id) == ["aud-1", "aud-2", "aud-3"])
        #expect(log.entries[2].actorDescription == "Render")
        #expect(!log.hasMore)
    }
}
