import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// The service-side view of env groups, which exists because the API has no endpoint for it.
@MainActor
@Suite("ServiceEnvGroupsStore")
struct ServiceEnvGroupsStoreTests {
    /// `nonisolated` because it's called from the transport's `@Sendable` route closure, which doesn't
    /// run on the main actor.
    private nonisolated static func groupsPage() -> String {
        Fixtures.envGroupsPage([
            Fixtures.envGroupMeta(id: "evg-1", name: "linked", links: [(id: "srv-1", name: "api", type: "web")]),
            Fixtures.envGroupMeta(id: "evg-2", name: "elsewhere", links: [(id: "srv-9", name: "other", type: "web")]),
            Fixtures.envGroupMeta(id: "evg-3", name: "unlinked"),
        ])
    }

    private func store(client: RenderClient, deployer: ConfigDeployer? = nil) -> ServiceEnvGroupsStore {
        ServiceEnvGroupsStore(
            client: client,
            ownerID: Fixtures.ownerID,
            serviceID: "srv-1",
            serviceName: "api",
            deployer: deployer
        )
    }

    @Test("the workspace's groups are split by whether this service is in serviceLinks")
    func splitsLinkedFromAvailable() async {
        // There is no `GET /services/{id}/env-groups`, so the only way to answer "which groups feed
        // this service" is to read every group's links.
        let (client, _) = RenderClient.routed { _ in (200, Self.groupsPage()) }
        let store = store(client: client)

        await store.load()

        #expect(store.linkedGroups.map(\.name) == ["linked"])
        #expect(store.availableGroups.map(\.name) == ["elsewhere", "unlinked"])
    }

    @Test("linking moves a group across and offers the deploy that makes it live")
    func linkMovesGroupAndOffersDeploy() async throws {
        // Linking changes exactly this service's configuration, so unlike a write *inside* a group,
        // one tap here really can make it live.
        let (client, transport) = RenderClient.routed { path in
            path.contains("/env-groups/evg-3/services/srv-1")
                ? (200, Fixtures.envGroup(id: "evg-3", name: "unlinked", links: [(id: "srv-1", name: "api", type: "web")]))
                : (200, Self.groupsPage())
        }
        let store = store(
            client: client,
            deployer: ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "api", source: .commit)
        )
        await store.load()

        let linked = await store.link(try #require(store.availableGroups.first { $0.name == "unlinked" }))

        #expect(linked)
        #expect(store.linkedGroups.map(\.name).sorted() == ["linked", "unlinked"])
        #expect(transport.requests.last?.method == .post)
        #expect(store.actionResult?.offersDeploy == true)
        #expect(store.actionResult?.message.contains("next deploy") == true)
    }

    @Test("unlinking edits the list itself, since that endpoint answers 204")
    func unlinkHandlesTheEmptyReply() async throws {
        // Every other group write hands back the whole group; this one hands back nothing.
        let (client, transport) = RenderClient.routed { path in
            path.contains("/env-groups/evg-1/services/srv-1") ? (204, "") : (200, Self.groupsPage())
        }
        let store = store(client: client)
        await store.load()

        let unlinked = await store.unlink(try #require(store.linkedGroups.first))

        #expect(unlinked)
        #expect(store.linkedGroups.isEmpty)
        #expect(store.availableGroups.map(\.name) == ["elsewhere", "linked", "unlinked"])
        #expect(transport.requests.last?.method == .delete)
    }

    @Test("a failed link changes nothing and says so")
    func failedLinkKeepsState() async throws {
        let (client, _) = RenderClient.routed { path in
            path.contains("/env-groups/evg-3/services/srv-1") ? (403, "{}") : (200, Self.groupsPage())
        }
        let store = store(client: client)
        await store.load()

        let linked = await store.link(try #require(store.availableGroups.first { $0.name == "unlinked" }))

        #expect(linked == false)
        #expect(store.linkedGroups.map(\.name) == ["linked"])
        #expect(store.actionResult?.isFailure == true)
    }
}

/// The live pass's most expensive finding, pinned from both directions.
@MainActor
@Suite("Unlink answers 200, not the documented 204")
struct UnlinkStatusCodeTests {
    private nonisolated static let group = Fixtures.envGroupMeta(
        id: "evg-1",
        name: "shared",
        links: [(id: "srv-1", name: "api", type: "web")]
    )

    @Test("a 200 from the service side is a success, not a failure banner")
    func serviceSideAccepts200() async throws {
        // Measured live: `DELETE /env-groups/{id}/services/{id}` answers **200**, and the generated
        // `.noContent` accessor throws on anything undocumented. So an unlink Render had performed was
        // reported as "Couldn't reach Render", with the stale row left on screen claiming a link that
        // no longer existed. Any 2xx now counts — see `NoContentWrite`.
        let (client, _) = RenderClient.routed { path in
            path.contains("/services/srv-1") && path.hasPrefix("/env-groups")
                ? (200, "")
                : (200, Fixtures.envGroupsPage([Self.group]))
        }
        let store = ServiceEnvGroupsStore(
            client: client,
            ownerID: Fixtures.ownerID,
            serviceID: "srv-1",
            serviceName: "api"
        )
        await store.load()

        let unlinked = await store.unlink(try #require(store.linkedGroups.first))

        #expect(unlinked)
        #expect(store.actionResult?.isFailure == false)
        #expect(store.linkedGroups.isEmpty)
    }

    @Test("a 200 from the group side is a success too")
    func groupSideAccepts200() async throws {
        // The group is loaded through the real client rather than decoded by hand: Render sends
        // microsecond timestamps, and only `RenderDateTranscoder` on the client copes with them.
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/env-groups/") ? (200, "") : (200, Fixtures.envGroupsPage([Self.group]))
        }
        let list = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID)
        await list.load()
        let store = EnvGroupDetailStore(client: client, group: try #require(list.groups.first))

        let unlinked = await store.unlink(try #require(store.sortedLinks.first))

        #expect(unlinked)
        #expect(store.actionResult?.isFailure == false)
        #expect(store.group.links.isEmpty)
    }

    @Test("a real failure is still a failure")
    func rejectsNon2xx() async throws {
        let (client, _) = RenderClient.routed { path in
            path.hasPrefix("/env-groups") && path.contains("/services/srv-1")
                ? (403, "{}")
                : (200, Fixtures.envGroupsPage([Self.group]))
        }
        let store = ServiceEnvGroupsStore(
            client: client,
            ownerID: Fixtures.ownerID,
            serviceID: "srv-1",
            serviceName: "api"
        )
        await store.load()

        let unlinked = await store.unlink(try #require(store.linkedGroups.first))

        #expect(unlinked == false)
        #expect(store.actionResult?.isFailure == true)
        #expect(store.linkedGroups.count == 1)
    }
}
