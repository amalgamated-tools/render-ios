import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("KeyValueDetailStore")
struct KeyValueDetailStoreTests {
    /// Routed rather than ordered stubs: the store fetches the detail and the connection info
    /// concurrently, so "the second body" would be a race.
    private func store(
        detail: (status: Int, body: String),
        connection: (status: Int, body: String) = (200, Fixtures.keyValueConnectionInfo),
        action: (status: Int, body: String) = (202, "{}")
    ) -> (KeyValueDetailStore, StubTransport) {
        let (client, transport) = RenderClient.routed { path in
            if path.contains("/connection-info") { return connection }
            if path.hasSuffix("/suspend") || path.hasSuffix("/resume") { return action }
            return detail
        }
        return (KeyValueDetailStore(client: client, keyValueID: "red-1"), transport)
    }

    @Test("load maps the instance and its connection info")
    func loadMapsBoth() async throws {
        let (store, transport) = store(
            detail: (200, Fixtures.keyValueJSON(includeDashboardURL: false))
        )

        await store.load()

        let instance = try #require(store.instance)
        #expect(instance.name == "cache")
        #expect(instance.maxmemoryPolicy == "allkeys_lru")
        #expect(instance.persistenceMode == .snapshot)
        #expect(instance.isSuspended == false)

        let connection = try #require(store.connection)
        #expect(connection.cliCommand == "valkey-cli -u rediss://external")

        // The legacy path spelling: Key Value endpoints live under /key-value/{redisId}.
        let paths = transport.requests.compactMap(\.path)
        #expect(paths.contains { $0.hasSuffix("/key-value/red-1") })
    }

    @Test("a connection-info failure doesn't blank a loaded instance")
    func connectionFailureIsIsolated() async throws {
        let (store, _) = store(
            detail: (200, Fixtures.keyValueJSON(includeDashboardURL: false)),
            connection: (403, #"{"message":"forbidden"}"#)
        )

        await store.load()

        #expect(store.instance != nil)
        #expect(store.connection == nil)
        #expect(store.connectionErrorMessage != nil)
        #expect(store.errorMessage == nil)
    }

    @Test("suspension is read from the status, the only place the schema carries it")
    func actionsFollowStatus() async throws {
        let (running, _) = store(detail: (200, Fixtures.keyValueJSON(includeDashboardURL: false)))
        await running.load()
        #expect(running.availableActions == [.suspend])

        let (suspended, _) = store(detail: (200, Fixtures.keyValueJSON(status: "suspended", includeDashboardURL: false)))
        await suspended.load()
        #expect(suspended.instance?.isSuspended == true)
        #expect(suspended.availableActions == [.resume])
    }

    @Test("a successful action posts a banner and reloads")
    func performSuccess() async throws {
        let (store, transport) = store(detail: (200, Fixtures.keyValueJSON(includeDashboardURL: false)))
        await store.load()

        await store.perform(.suspend)

        let result = try #require(store.actionResult)
        #expect(result.isFailure == false)
        let paths = transport.requests.compactMap(\.path)
        #expect(paths.contains { $0.hasSuffix("/key-value/red-1/suspend") })
    }

    @Test("a failed action posts a failure banner")
    func performFailure() async throws {
        let (store, _) = store(
            detail: (200, Fixtures.keyValueJSON(includeDashboardURL: false)),
            action: (400, #"{"message":"cannot suspend"}"#)
        )
        await store.load()

        await store.perform(.suspend)

        let result = try #require(store.actionResult)
        #expect(result.isFailure)
        // A 400 carries Render's own reason, which says more than the status code would.
        #expect(result.message == "Cannot suspend.")
    }
}
