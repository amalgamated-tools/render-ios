import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("PostgresDetailStore")
struct PostgresDetailStoreTests {
    /// Routed rather than ordered stubs: the store fetches the detail and the connection info
    /// concurrently, so "the second body" would be a race.
    private func store(
        detail: (status: Int, body: String),
        connection: (status: Int, body: String) = (200, Fixtures.postgresConnectionInfo()),
        action: (status: Int, body: String) = (202, "{}")
    ) -> (PostgresDetailStore, StubTransport) {
        let (client, transport) = RenderClient.routed { path in
            if path.contains("/connection-info") { return connection }
            if path.hasSuffix("/suspend") || path.hasSuffix("/resume")
                || path.hasSuffix("/restart") || path.hasSuffix("/failover") {
                return action
            }
            return detail
        }
        return (PostgresDetailStore(client: client, postgresID: "dpg-1"), transport)
    }

    @Test("load maps the database and its connection info")
    func loadMapsBoth() async throws {
        let (store, _) = store(
            detail: (200, Fixtures.postgresJSON(readReplicaNames: ["appdb-replica"], maintenanceScheduledAt: "2026-09-01T00:00:00Z")),
            connection: (200, Fixtures.postgresConnectionInfo(withPoolStrings: true))
        )

        await store.load()

        let database = try #require(store.database)
        #expect(database.databaseName == "appdb")
        #expect(database.databaseUser == "appuser")
        #expect(database.diskSizeGB == 10)
        #expect(database.isDiskAutoscalingEnabled)
        #expect(database.readReplicaNames == ["appdb-replica"])
        #expect(database.maintenanceScheduledAt != nil)

        let connection = try #require(store.connection)
        #expect(connection.password == "hunter2")
        #expect(connection.internalConnectionPoolString == "postgres://pool-internal")
        #expect(store.errorMessage == nil)
        #expect(store.connectionErrorMessage == nil)
    }

    @Test("a connection-info failure doesn't blank a loaded database")
    func connectionFailureIsIsolated() async throws {
        let (store, _) = store(
            detail: (200, Fixtures.postgresJSON()),
            connection: (403, #"{"message":"forbidden"}"#)
        )

        await store.load()

        #expect(store.database != nil)
        #expect(store.connection == nil)
        #expect(store.connectionErrorMessage != nil)
        #expect(store.errorMessage == nil)
    }

    @Test("a detail failure surfaces as the screen's error")
    func detailFailure() async throws {
        let (store, _) = store(detail: (500, #"{"message":"nope"}"#))

        await store.load()

        #expect(store.database == nil)
        #expect(store.errorMessage != nil)
    }

    // MARK: - Available actions

    private func actions(
        suspended: String = "not_suspended",
        role: String = "primary",
        highAvailability: Bool = false,
        status: String = "available"
    ) async -> [PostgresAction] {
        let (store, _) = store(detail: (200, Fixtures.postgresJSON(
            status: status,
            suspended: suspended,
            role: role,
            highAvailability: highAvailability
        )))
        await store.load()
        return store.availableActions
    }

    @Test("a running database offers restart and suspend")
    func runningActions() async {
        #expect(await actions() == [.restart, .suspend])
    }

    @Test("a suspended database offers resume only")
    func suspendedActions() async {
        // No restart: there is nothing running to restart, and the two would sit one row apart.
        #expect(await actions(suspended: "suspended", status: "suspended") == [.resume])
    }

    @Test("failover needs HA, a primary, and an available database")
    func failoverGating() async {
        #expect(await actions(highAvailability: true) == [.restart, .failover, .suspend])
        // A replica has no standby of its own to promote.
        #expect(await actions(role: "replica", highAvailability: true) == [.restart, .suspend])
        // Mid-transition, the standby may be the thing being replaced.
        #expect(await actions(highAvailability: true, status: "updating_instance") == [.restart, .suspend])
    }

    // MARK: - Performing actions

    @Test("a successful action posts a banner and reloads")
    func performSuccess() async throws {
        let (store, transport) = store(detail: (200, Fixtures.postgresJSON()))
        await store.load()
        let callsBefore = transport.callCount

        await store.perform(.suspend)

        let result = try #require(store.actionResult)
        #expect(result.isFailure == false)
        #expect(result.message == PostgresAction.suspend.successMessage)
        let paths = transport.requests.compactMap(\.path)
        #expect(paths.contains { $0.hasSuffix("/postgres/dpg-1/suspend") })
        // The action plus the reload's two GETs.
        #expect(transport.callCount == callsBefore + 3)
    }

    @Test("a failed action posts a failure banner and still reloads")
    func performFailure() async throws {
        let (store, transport) = store(
            detail: (200, Fixtures.postgresJSON()),
            action: (400, #"{"message":"cannot restart now"}"#)
        )
        await store.load()

        await store.perform(.restart)

        let result = try #require(store.actionResult)
        #expect(result.isFailure)
        // A 400 carries Render's own reason, which says more than the status code would.
        #expect(result.message == "Cannot restart now.")
        // Reloaded anyway: a failed action can still have changed state.
        let getCount = transport.requests.filter { $0.method == .get }.count
        #expect(getCount == 4)
    }
}
