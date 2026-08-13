import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("EnvGroupsStore")
struct EnvGroupsStoreTests {
    @Test("the whole list is drained through the cursor the live API actually returns")
    func drainsEveryPage() async throws {
        // The vendored spec said this response was a bare array of envGroupMeta. It isn't: the live API
        // wraps each group in the usual {envGroup, cursor} envelope, and because envGroupMeta marks six
        // fields required, the strict decoder rejected every real reply — the screen couldn't load at
        // all. `Scripts/envelope-env-groups.py` patches the spec to match; this test rides on that
        // envelope, so losing the patch fails here rather than only in production.
        let attempts = Counter()
        let (client, transport) = RenderClient.routed { _ in
            attempts.next() == 1
                ? (200, Fixtures.envGroupsPage([
                    Fixtures.envGroupMeta(id: "evg-1", name: "b"),
                    Fixtures.envGroupMeta(id: "evg-2", name: "a"),
                  ]))
                : (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-3", name: "c")]))
        }
        let store = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID, pageSize: 2)

        await store.load()

        #expect(transport.callCount == 2)
        #expect(store.sortedGroups.map(\.name) == ["a", "b", "c"])
        // The second request carries the cursor the first page ended on.
        #expect(try #require(transport.requests.last?.path).contains("cursor=cursor-evg-2"))
    }

    @Test("the list is scoped to the workspace and not to a project")
    func scopedToOwnerOnly() async throws {
        // Deliberate: a group can be linked to services across projects, so an environmentId filter
        // would hide groups the current project is actually using.
        let (client, transport) = RenderClient.routed { _ in
            (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "a")]))
        }
        let store = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID)

        await store.load()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("ownerId=\(Fixtures.ownerID)"))
        #expect(!path.contains("environmentId"))
    }

    @Test("the link count is read off serviceLinks, since nothing else records it")
    func linkCount() async {
        let (client, _) = RenderClient.routed { _ in
            (200, Fixtures.envGroupsPage([
                Fixtures.envGroupMeta(
                    id: "evg-1",
                    name: "shared",
                    links: [(id: "srv-1", name: "api", type: "web"), (id: "srv-2", name: "worker", type: "worker")]
                )
            ]))
        }
        let store = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID)

        await store.load()

        #expect(store.groups.first?.linkedServiceCount == 2)
        #expect(store.groups.first?.linkSummary == "2 linked services")
    }

    @Test("creating sends an empty, workspace-wide group and adds the row")
    func createsEmptyGroup() async throws {
        let recorder = BodyRecorder()
        let store = EnvGroupsStore(
            client: recorder.client(answering: Fixtures.envGroup(id: "evg-9", name: "shared"), status: 201),
            ownerID: Fixtures.ownerID
        )

        let created = await store.create(name: "  shared  ")

        #expect(created?.name == "shared")
        #expect(store.groups.map(\.name) == ["shared"])
        let body = try #require(recorder.compactBodies.first)
        // Empty on purpose — the variables go in through the group's own screen.
        #expect(body.contains(#""envVars":[]"#))
        #expect(body.contains(#""name":"shared""#))
        // No environmentId: guessing one from a multi-environment project scope would file the group
        // where nobody asked and then hide it from the list that created it.
        #expect(!body.contains("environmentId"))
    }

    @Test("a duplicate name is caught before it reaches the network")
    func duplicateNameRejected() async {
        let (client, transport) = RenderClient.routed { _ in
            (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "shared")]))
        }
        let store = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID)
        await store.load()
        let callsAfterLoad = transport.callCount

        #expect(store.containsName(" SHARED "))

        // The sheet disables Create on this, so nothing should have been sent.
        #expect(transport.callCount == callsAfterLoad)
    }

    @Test("deleting drops the row and reports")
    func deleteRemovesRow() async throws {
        let (client, transport) = RenderClient.routed { path in
            path.hasPrefix("/env-groups/evg-1")
                ? (204, "")
                : (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "shared")]))
        }
        let store = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID)
        await store.load()

        let deleted = await store.delete(try #require(store.groups.first))

        #expect(deleted)
        #expect(store.groups.isEmpty)
        #expect(transport.requests.last?.method == .delete)
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("a failed refresh keeps the list that's on screen")
    func failedRefreshKeepsGroups() async {
        let attempts = Counter()
        let (client, _) = RenderClient.routed { _ in
            attempts.next() == 1
                ? (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "shared")]))
                : (500, "{}")
        }
        let store = EnvGroupsStore(client: client, ownerID: Fixtures.ownerID)
        await store.load()

        await store.refresh()

        #expect(store.errorMessage != nil)
        #expect(store.groups.map(\.name) == ["shared"])
    }
}
