import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// A Postgres database's users: listing, adding (which rotates the default), and deleting.
@MainActor
@Suite("PostgresUsersStore")
struct PostgresUsersStoreTests {
    /// What Render answers, changeable mid-test, plus what the store sent it.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: (Int, String) = (200, PostgresUsersStoreTests.listJSON([
            ("app_user", true, "2026-11-17T01:47:24.91181Z", 2),
        ]))
        // The statuses Render answered live, not the 202 and 200 the spec documents.
        private var _create: (Int, String) = (201, "{}")
        private var _delete: (Int, String) = (204, "")
        private var _createBodies: [[String: String]] = []
        private var _listGate: Gate?
        private var _createGate: Gate?

        /// Holds the next list read, after it has taken its answer, until the gate opens.
        func holdNextList(at gate: Gate) { lock.withLock { _listGate = gate } }
        func takeListGate() -> Gate? { lock.withLock { defer { _listGate = nil }; return _listGate } }

        /// Holds the next create, before it's answered, until the gate opens.
        func holdNextCreate(at gate: Gate) { lock.withLock { _createGate = gate } }
        func takeCreateGate() -> Gate? { lock.withLock { defer { _createGate = nil }; return _createGate } }

        var list: (Int, String) {
            get { lock.withLock { _list } }
            set { lock.withLock { _list = newValue } }
        }

        var create: (Int, String) {
            get { lock.withLock { _create } }
            set { lock.withLock { _create = newValue } }
        }

        var delete: (Int, String) {
            get { lock.withLock { _delete } }
            set { lock.withLock { _delete = newValue } }
        }

        var createBodies: [[String: String]] {
            get { lock.withLock { _createBodies } }
            set { lock.withLock { _createBodies = newValue } }
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

    private nonisolated static func listJSON(_ users: [(String, Bool, String, Int)]) -> String {
        "[" + users.map {
            #"{"username":"\#($0.0)","default":\#($0.1),"createdAt":"\#($0.2)","openConnections":\#($0.3)}"#
        }.joined(separator: ",") + "]"
    }

    private func store(_ backend: Backend) -> (PostgresUsersStore, StubTransport) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            let answer: (Int, String)
            switch request.method {
            case .post where path.hasSuffix("/credentials"):
                var data = Data()
                if let body { data = try await Data(collecting: body, upTo: 4096) }
                backend.createBodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: String]) ?? [:])
                if let gate = backend.takeCreateGate() { await gate.hold() }
                answer = backend.create
            case .delete:
                answer = backend.delete
            default:
                answer = backend.list
                if let gate = backend.takeListGate() { await gate.hold() }
            }
            var response = HTTPResponse(status: .init(code: answer.0))
            response.headerFields = [.contentType: "application/json"]
            return (response, answer.1.isEmpty ? nil : HTTPBody(answer.1))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        return (PostgresUsersStore(client: client, postgresID: "dpg-1"), transport)
    }

    // MARK: - Parsing and rules

    @Test("createdAt parses with nine, six or no fractional digits")
    func parsesDates() throws {
        let nine = try #require(PostgresUser.parseDate("2026-11-17T01:48:27.490331884Z"))
        let six = try #require(PostgresUser.parseDate("2026-11-17T01:48:27.490331Z"))
        let none = try #require(PostgresUser.parseDate("2026-11-17T01:48:27Z"))
        #expect(abs(nine.timeIntervalSince(none) - 0.49) < 0.001)
        #expect(nine == six)
        #expect(PostgresUser.parseDate(nil) == nil)
        #expect(PostgresUser.parseDate("not a date") == nil)
    }

    @Test("a new username follows Render's rules and must be new")
    func usernameRules() async {
        let (store, _) = store(Backend())
        await store.load()

        #expect(store.validationMessage(forNewUsername: "app_v2") == nil)
        #expect(store.validationMessage(forNewUsername: "") != nil)
        // Render's live answer: "only a-z, 0-9, and underscore (_) characters are allowed".
        #expect(store.validationMessage(forNewUsername: "Bad Name!") != nil)
        #expect(store.validationMessage(forNewUsername: "App") != nil)
        #expect(store.validationMessage(forNewUsername: "café") != nil)
        #expect(store.validationMessage(forNewUsername: "app_user") == "app_user already exists.")
        #expect(store.validationMessage(forNewUsername: String(repeating: "a", count: 64)) != nil)
    }

    // MARK: - Loading

    @Test("the default user is listed first, then the newest")
    func sortsDefaultFirst() async {
        let backend = Backend()
        backend.list = (200, Self.listJSON([
            ("old_user", false, "2026-11-01T00:00:00Z", 0),
            ("app_v2", true, "2026-11-17T01:48:27.490331884Z", 1),
            ("newer_user", false, "2026-11-10T00:00:00Z", 3),
        ]))
        let (store, _) = store(backend)

        await store.load()

        #expect(store.users.map(\.username) == ["app_v2", "newer_user", "old_user"])
        #expect(store.defaultUser?.username == "app_v2")
        #expect(store.users[1].openConnections == 3)
    }

    // MARK: - Adding

    @Test("adding sends the username, accepts Render's 201, and reloads with the new default")
    func addRotatesDefault() async throws {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()
        backend.list = (200, Self.listJSON([
            ("app_v2", true, "2026-11-17T02:00:00Z", 0),
            ("app_user", false, "2026-11-17T01:47:24.91181Z", 2),
        ]))

        let added = await store.add(username: "app_v2")

        #expect(added)
        #expect(backend.createBodies == [["username": "app_v2"]])
        #expect(store.defaultUser?.username == "app_v2")
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("an invalid username is never sent")
    func invalidUsernameNotSent() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()

        let added = await store.add(username: "Bad Name!")

        #expect(!added)
        #expect(backend.createBodies.isEmpty)
    }

    @Test("a create Render refuses shows Render's reason")
    func addRefused() async {
        let backend = Backend()
        backend.create = (400, #"{"message":"user \"app_v2\" already exists"}"#)
        let (store, _) = store(backend)
        await store.load()

        let added = await store.add(username: "app_v2")

        #expect(!added)
        #expect(store.actionResult?.isFailure == true)
        #expect(store.actionResult?.message == #"User "app_v2" already exists."#)
    }

    // MARK: - Deleting

    @Test("deleting accepts Render's 204 and removes the row")
    func deleteRemovesRow() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([
            ("app_v2", true, "2026-11-17T02:00:00Z", 0),
            ("app_user", false, "2026-11-17T01:47:24.91181Z", 0),
        ]))
        let (store, transport) = store(backend)
        await store.load()
        let old = try #require(store.users.first { $0.username == "app_user" })

        await store.delete(old)

        #expect(transport.requests.contains { $0.method == .delete && ($0.path ?? "").hasSuffix("/postgres/dpg-1/credentials/app_user") })
        #expect(store.users.map(\.username) == ["app_v2"])
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("the default user is never sent for deletion")
    func defaultNotDeleted() async throws {
        let (store, transport) = store(Backend())
        await store.load()
        let user = try #require(store.defaultUser)

        await store.delete(user)

        #expect(!transport.requests.contains { $0.method == .delete })
        #expect(store.users.count == 1)
    }

    @Test("a delete Render refuses shows its reason and keeps the row")
    func deleteRefused() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([
            ("app_v2", true, "2026-11-17T02:00:00Z", 0),
            ("app_user", false, "2026-11-17T01:47:24.91181Z", 0),
        ]))
        backend.delete = (400, #"{"message":"cannot delete unmanaged credential"}"#)
        let (store, _) = store(backend)
        await store.load()
        let old = try #require(store.users.first { $0.username == "app_user" })

        await store.delete(old)

        #expect(store.users.map(\.username) == ["app_v2", "app_user"])
        #expect(store.actionResult?.message == "Cannot delete unmanaged credential.")
    }

    // MARK: - Overlapping refreshes

    @Test("a refresh that started before a delete can't bring the deleted row back")
    func staleRefreshAfterDelete() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([
            ("app_v2", true, "2026-11-17T02:00:00Z", 0),
            ("app_user", false, "2026-11-17T01:47:24.91181Z", 0),
        ]))
        let (store, _) = store(backend)
        await store.load()
        let old = try #require(store.users.first { $0.username == "app_user" })

        // The refresh reads the list with app_user still in it, and is held.
        let gate = Gate()
        backend.holdNextList(at: gate)
        let refresh = Task { await store.load() }
        await gate.waitUntilEntered()

        await store.delete(old)
        #expect(store.users.map(\.username) == ["app_v2"])

        await gate.open()
        await refresh.value
        #expect(store.users.map(\.username) == ["app_v2"], "the older list must not win")
    }

    @Test("a refresh that started during an add can't replace the new default")
    func refreshDuringAdd() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()

        // The create is held before Render answers it.
        let createGate = Gate()
        backend.holdNextCreate(at: createGate)
        let add = Task { await store.add(username: "app_v2") }
        await createGate.waitUntilEntered()

        // A refresh starts mid-add, reads the list from before it, and is held.
        let listGate = Gate()
        backend.holdNextList(at: listGate)
        let refresh = Task { await store.load() }
        await listGate.waitUntilEntered()

        backend.list = (200, Self.listJSON([
            ("app_v2", true, "2026-11-17T02:00:00Z", 0),
            ("app_user", false, "2026-11-17T01:47:24.91181Z", 2),
        ]))
        await createGate.open()
        _ = await add.value
        #expect(store.defaultUser?.username == "app_v2")

        await listGate.open()
        await refresh.value
        #expect(store.defaultUser?.username == "app_v2", "the refresh that started mid-add must not win")
        #expect(store.users.count == 2)
    }
}
