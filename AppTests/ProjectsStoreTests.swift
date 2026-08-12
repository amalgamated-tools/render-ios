import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("ProjectsStore")
struct ProjectsStoreTests {
    private func store(
        bodies: [String],
        status: Int = 200,
        defaults: UserDefaults = makeTestDefaults()
    ) -> (ProjectsStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(jsonBodies: bodies, status: status)
        return (ProjectsStore(client: client, ownerID: Fixtures.ownerID, defaults: defaults), transport)
    }

    @Test("projects come back sorted by name, with their environments")
    func loadsAndSorts() async throws {
        let (store, transport) = store(bodies: [
            Fixtures.projectsPage([
                (id: "prj-2", name: "Website", environmentIDs: ["evm-3"]),
                (id: "prj-1", name: "brand assets", environmentIDs: ["evm-1", "evm-2"]),
            ])
        ])

        await store.load()

        #expect(store.projects.map(\.name) == ["brand assets", "Website"])
        #expect(store.projects.first?.environmentIDs == ["evm-1", "evm-2"])
        #expect(store.errorMessage == nil)
        // Scoped to the owner, not the whole account.
        #expect(transport.requests.first?.path?.contains("ownerId=\(Fixtures.ownerID)") == true)
    }

    @Test("no selection means no environment filter")
    func unscopedByDefault() async throws {
        let (store, _) = store(bodies: [Fixtures.projectsPage([(id: "prj-1", name: "Website", environmentIDs: ["evm-1"])])])

        await store.load()

        #expect(store.selectedProjectID == nil)
        #expect(store.selectedEnvironmentIDs == nil)
    }

    @Test("selecting a project surfaces its environments as the filter")
    func selectionDrivesFilter() async throws {
        let (store, _) = store(bodies: [
            Fixtures.projectsPage([(id: "prj-1", name: "Website", environmentIDs: ["evm-1", "evm-2"])])
        ])

        await store.load()
        store.selectedProjectID = "prj-1"

        #expect(store.selectedEnvironmentIDs == ["evm-1", "evm-2"])
        #expect(store.selectedProject?.name == "Website")
    }

    @Test("the selected project is remembered per owner")
    func persistsSelection() async throws {
        let defaults = makeTestDefaults()
        let page = Fixtures.projectsPage([(id: "prj-1", name: "Website", environmentIDs: ["evm-1"])])

        let (first, _) = store(bodies: [page], defaults: defaults)
        await first.load()
        first.selectedProjectID = "prj-1"

        // A fresh store stands in for the next launch.
        let (second, _) = store(bodies: [page], defaults: defaults)
        #expect(second.selectedProjectID == "prj-1")
        // …but the scope isn't resolvable until the projects arrive, which is why the screen waits.
        #expect(second.hasLoaded == false)
        #expect(second.selectedEnvironmentIDs == nil)

        await second.load()
        #expect(second.selectedEnvironmentIDs == ["evm-1"])
    }

    @Test("a remembered project that no longer exists is dropped")
    func clearsStaleSelection() async throws {
        let defaults = makeTestDefaults()
        defaults.set("prj-deleted", forKey: "selectedProjectID.\(Fixtures.ownerID)")
        let (store, _) = store(
            bodies: [Fixtures.projectsPage([(id: "prj-1", name: "Website", environmentIDs: ["evm-1"])])],
            defaults: defaults
        )

        await store.load()

        // Otherwise the list would stay filtered by a project the picker can't show or clear.
        #expect(store.selectedProjectID == nil)
    }

    @Test("a failed load reports the error and still finishes loading")
    func failureIsNonFatal() async throws {
        let (store, _) = store(bodies: [#"{"message":"nope"}"#], status: 500)

        await store.load()

        #expect(store.projects.isEmpty)
        #expect(store.errorMessage != nil)
        // hasLoaded gates the service list; leaving it false would hang the screen on a spinner.
        #expect(store.hasLoaded)
    }
}
