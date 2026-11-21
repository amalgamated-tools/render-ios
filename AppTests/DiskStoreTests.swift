import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("DiskStore")
struct DiskStoreTests {
    private nonisolated static let snapshots = #"""
    [
      {"createdAt": "2026-11-19T00:10:00Z", "instanceId": "srv-1", "snapshotKey": "key-older"},
      {"createdAt": "2026-11-21T00:10:00Z", "instanceId": "srv-1", "snapshotKey": "key-newest"},
      {"instanceId": "srv-1", "snapshotKey": "key-undated"},
      {"createdAt": "2026-11-20T00:10:00Z", "instanceId": "srv-1"}
    ]
    """#

    private func store(
        _ route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (DiskStore, StubTransport) {
        let (client, transport) = RenderClient.routed(route: route)
        return (DiskStore(client: client, diskID: "dsk-1"), transport)
    }

    @Test("snapshots load from a 200, newest first, undated last, keyless dropped")
    func loads() async {
        let (store, _) = store { path in
            path.hasSuffix("/disks/dsk-1/snapshots") ? (200, Self.snapshots) : (404, "{}")
        }

        await store.load()

        #expect(store.error == nil)
        #expect(store.hasLoaded)
        #expect(store.snapshots.map(\.id) == ["key-newest", "key-older", "key-undated"])
        #expect(store.snapshots.first?.instanceID == "srv-1")
    }

    @Test("an empty list is loaded, not an error")
    func empty() async {
        let (store, _) = store { _ in (200, "[]") }

        await store.load()

        #expect(store.hasLoaded && store.snapshots.isEmpty && store.error == nil)
    }

    @Test("a failed reload keeps the snapshots already shown")
    func failureKeepsSnapshots() async {
        let fail = LockedFlag()
        let (store, _) = store { _ in
            fail.value ? (500, #"{"message":"boom"}"#) : (200, Self.snapshots)
        }

        await store.load()
        fail.value = true
        await store.load()

        #expect(store.snapshots.count == 3)
        #expect(store.error != nil)
    }
}
