import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("PostgresStore")
struct PostgresStoreTests {
    private func store(
        environmentIDs: [String]? = nil,
        bodies: [String],
        status: Int = 200,
        pageSize: Int = 50
    ) -> (PostgresStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(jsonBodies: bodies, status: status)
        let store = PostgresStore(
            client: client,
            ownerID: Fixtures.ownerID,
            environmentIDs: environmentIDs,
            pageSize: pageSize
        )
        return (store, transport)
    }

    @Test("an unscoped list asks for the whole workspace, replicas included")
    func unscopedQuery() async throws {
        let (store, transport) = store(bodies: [Fixtures.postgresPage([(id: "dpg-1", name: "appdb")])])

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("ownerId=\(Fixtures.ownerID)"))
        #expect(path.contains("includeReplicas=true"))
        #expect(!path.contains("environmentId"))
        #expect(store.isProjectScoped == false)
        #expect(store.databases.map(\.name) == ["appdb"])
    }

    @Test("a project scope is sent as its environments")
    func scopedQuery() async throws {
        let (store, transport) = store(
            environmentIDs: ["evm-1", "evm-2"],
            bodies: [Fixtures.postgresPage([(id: "dpg-1", name: "appdb")])]
        )

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("environmentId=evm-1,evm-2"))
        #expect(store.isProjectScoped)
    }

    @Test("a project with no environments returns nothing without asking the API")
    func emptyScopeShortCircuits() async throws {
        let (store, transport) = store(
            environmentIDs: [],
            bodies: [Fixtures.postgresPage([(id: "dpg-1", name: "appdb")])]
        )

        await store.refresh()

        #expect(transport.callCount == 0)
        #expect(store.databases.isEmpty)
        #expect(store.hasMore == false)
    }

    @Test("the summary maps the enum-shaped fields the row reads")
    func summaryMapping() async throws {
        let (store, _) = store(bodies: [
            "[" + #"{"postgres":\#(Fixtures.postgresJSON(id: "dpg-1", name: "appdb", suspended: "suspended", role: "replica")),"cursor":"c-1"}"# + "]"
        ])

        await store.refresh()

        let database = try #require(store.databases.first)
        #expect(database.isSuspended)
        #expect(database.role == .replica)
        // `basic_1gb` → human-readable, without a per-schema plan enum.
        #expect(database.planDisplayName == "Basic 1Gb")
        #expect(database.version == "16")
    }

    @Test("search applies over the loaded pages, sorted by name")
    func searchFiltersAndSorts() async throws {
        let (store, _) = store(bodies: [
            Fixtures.postgresPage([(id: "dpg-1", name: "prod-db"), (id: "dpg-2", name: "dev-db")])
        ])

        await store.refresh()
        #expect(store.visibleDatabases.map(\.name) == ["dev-db", "prod-db"])

        store.searchText = "  PROD "
        #expect(store.visibleDatabases.map(\.name) == ["prod-db"])
    }

    @Test("a short page ends the list")
    func shortPageStopsPaging() async throws {
        let (store, transport) = store(
            bodies: [Fixtures.postgresPage([(id: "dpg-1", name: "appdb")])],
            pageSize: 2
        )

        await store.refresh()
        #expect(store.hasMore == false)

        await store.loadNextPage()
        #expect(transport.callCount == 1)
    }

    @Test("a failed load surfaces a message and stops paging")
    func failureStopsPaging() async throws {
        let (store, _) = store(bodies: [#"{"message":"nope"}"#], status: 500)

        await store.refresh()

        #expect(store.errorMessage != nil)
        #expect(store.hasMore == false)
    }
}
