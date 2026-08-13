import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("KeyValueStore")
struct KeyValueStoreTests {
    private func store(
        environmentIDs: [String]? = nil,
        bodies: [String],
        status: Int = 200,
        pageSize: Int = 50
    ) -> (KeyValueStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(jsonBodies: bodies, status: status)
        let store = KeyValueStore(
            client: client,
            ownerID: Fixtures.ownerID,
            environmentIDs: environmentIDs,
            pageSize: pageSize
        )
        return (store, transport)
    }

    @Test("an unscoped list asks for the whole workspace")
    func unscopedQuery() async throws {
        let (store, transport) = store(bodies: [Fixtures.keyValuePage([(id: "red-1", name: "cache")])])

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("/key-value"))
        #expect(path.contains("ownerId=\(Fixtures.ownerID)"))
        #expect(!path.contains("environmentId"))
        #expect(store.instances.map(\.name) == ["cache"])
    }

    @Test("a project scope is sent as its environments")
    func scopedQuery() async throws {
        let (store, transport) = store(
            environmentIDs: ["evm-1"],
            bodies: [Fixtures.keyValuePage([(id: "red-1", name: "cache")])]
        )

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("environmentId=evm-1"))
        #expect(store.isProjectScoped)
    }

    @Test("a project with no environments returns nothing without asking the API")
    func emptyScopeShortCircuits() async throws {
        let (store, transport) = store(
            environmentIDs: [],
            bodies: [Fixtures.keyValuePage([(id: "red-1", name: "cache")])]
        )

        await store.refresh()

        #expect(transport.callCount == 0)
        #expect(store.instances.isEmpty)
        #expect(store.hasMore == false)
    }

    @Test("the summary carries the dashboard URL the detail schema lacks")
    func summaryMapping() async throws {
        let (store, _) = store(bodies: [Fixtures.keyValuePage([(id: "red-1", name: "cache")])])

        await store.refresh()

        let instance = try #require(store.instances.first)
        #expect(instance.planDisplayName == "Starter")
        #expect(instance.version == "8")
        #expect(instance.dashboardURL != nil)
    }

    @Test("a short page ends the list")
    func shortPageStopsPaging() async throws {
        let (store, transport) = store(
            bodies: [Fixtures.keyValuePage([(id: "red-1", name: "cache")])],
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
