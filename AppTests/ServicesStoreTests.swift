import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("ServicesStore")
struct ServicesStoreTests {
    private func store(
        environmentIDs: [String]? = nil,
        bodies: [String],
        status: Int = 200,
        pageSize: Int = 50
    ) -> (ServicesStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(jsonBodies: bodies, status: status)
        let store = ServicesStore(
            client: client,
            ownerID: Fixtures.ownerID,
            environmentIDs: environmentIDs,
            pageSize: pageSize
        )
        return (store, transport)
    }

    @Test("an unscoped list asks for the whole workspace")
    func unscopedQuery() async throws {
        let (store, transport) = store(bodies: [Fixtures.servicesPage([(id: "srv-1", name: "api")])])

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("ownerId=\(Fixtures.ownerID)"))
        #expect(!path.contains("environmentId"))
        #expect(store.isProjectScoped == false)
        #expect(store.services.map(\.name) == ["api"])
    }

    @Test("a project scope is sent as its environments")
    func scopedQuery() async throws {
        let (store, transport) = store(
            environmentIDs: ["evm-1", "evm-2"],
            bodies: [Fixtures.servicesPage([(id: "srv-1", name: "api")])]
        )

        await store.refresh()

        let path = try #require(transport.requests.first?.path)
        // Services hang off environments, not projects, so this is what "scope by project" becomes.
        // The spec declares `environmentId` as `style: form, explode: false`, i.e. one comma-joined
        // parameter rather than one per value.
        #expect(path.contains("environmentId=evm-1,evm-2"))
        #expect(store.isProjectScoped)
    }

    @Test("a project with no environments returns nothing without asking the API")
    func emptyScopeShortCircuits() async throws {
        // An empty environmentId filter is sent as no filter at all, which would quietly widen the
        // list back to the entire workspace.
        let (store, transport) = store(
            environmentIDs: [],
            bodies: [Fixtures.servicesPage([(id: "srv-1", name: "api")])]
        )

        await store.refresh()

        #expect(transport.callCount == 0)
        #expect(store.services.isEmpty)
        #expect(store.hasMore == false)
    }

    @Test("search and type filters apply over the loaded pages, sorted by name")
    func filtersAndSorts() async throws {
        let (store, _) = store(bodies: [
            Fixtures.servicesPage([
                (id: "srv-1", name: "web-two"),
                (id: "srv-2", name: "api-one"),
            ])
        ])

        await store.refresh()
        #expect(store.visibleServices.map(\.name) == ["api-one", "web-two"])

        store.searchText = "  API "
        #expect(store.visibleServices.map(\.name) == ["api-one"])

        store.searchText = ""
        store.typeFilter = .cronJob
        #expect(store.visibleServices.isEmpty)
    }

    @Test("a short page ends the list")
    func shortPageStopsPaging() async throws {
        let (store, transport) = store(
            bodies: [Fixtures.servicesPage([(id: "srv-1", name: "api")])],
            pageSize: 2
        )

        await store.refresh()
        #expect(store.hasMore == false)

        // No cursor to resume from, so this must not fire a second request.
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
