import Foundation
import HTTPTypes
import OpenAPIRuntime
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

    private nonisolated static func disk(sizeGB: Int) -> String {
        #"{"id":"dsk-1","name":"data","sizeGB":\#(sizeGB),"mountPath":"/data","serviceId":"srv-1","#
            + #""createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-11-21T00:00:00Z"}"#
    }

    private func store(
        _ route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (DiskStore, StubTransport) {
        let (client, transport) = RenderClient.routed(route: route)
        return (DiskStore(client: client, diskID: "dsk-1", sizeGB: 10), transport)
    }

    /// A store whose stub sees the method and request body, for the writes.
    private func writingStore(
        recorder: Recorder,
        _ route: @escaping @Sendable (HTTPRequest.Method, String) -> (status: Int, body: String)
    ) -> DiskStore {
        DiskStore(client: writingClient(recorder: recorder, route), diskID: "dsk-1", sizeGB: 10)
    }

    // MARK: - Reading

    @Test("snapshots load from a 200, newest first, undated last, keyless dropped")
    func loads() async {
        let (store, _) = store { path in
            path.hasSuffix("/disks/dsk-1/snapshots") ? (200, Self.snapshots) : (404, "{}")
        }

        await store.load()

        #expect(store.error == nil)
        #expect(store.hasLoaded)
        #expect(store.snapshots.map(\.key) == ["key-newest", "key-older", "key-undated"])
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

    // MARK: - Resizing

    @Test("only a larger size is accepted")
    func resizeValidation() {
        let (store, _) = store { _ in (200, "[]") }

        #expect(store.resizeValidationMessage(nil) != nil)
        #expect(store.resizeValidationMessage(10) != nil)
        #expect(store.resizeValidationMessage(5) != nil)
        #expect(store.resizeValidationMessage(11) == nil)
    }

    @Test("resizing PATCHes only sizeGB and shows the size Render answers with")
    func resizes() async throws {
        let recorder = Recorder()
        let store = writingStore(recorder: recorder) { method, path in
            method == .patch && path.hasSuffix("/disks/dsk-1") ? (200, Self.disk(sizeGB: 20)) : (404, "{}")
        }

        await store.resize(to: 20)

        let request = try #require(recorder.requests.first)
        #expect(request.method == .patch)
        let body = try JSONSerialization.jsonObject(with: Data((request.body ?? "").utf8)) as? [String: Int]
        #expect(body == ["sizeGB": 20])
        #expect(store.sizeGB == 20)
        #expect(store.actionResult?.isFailure == false)
        #expect(!store.isResizing)
    }

    @Test("a smaller size is never sent")
    func refusesShrink() async {
        let recorder = Recorder()
        let store = writingStore(recorder: recorder) { _, _ in (200, Self.disk(sizeGB: 5)) }

        await store.resize(to: 5)

        #expect(recorder.requests.isEmpty)
        #expect(store.sizeGB == 10)
    }

    @Test("a failed resize keeps the old size and reports the failure")
    func resizeFails() async {
        let store = writingStore(recorder: Recorder()) { _, _ in (400, #"{"message":"too big"}"#) }

        await store.resize(to: 20)

        #expect(store.sizeGB == 10)
        #expect(store.actionResult?.isFailure == true)
    }

    // MARK: - Restoring

    @Test("restoring refetches the list and sends the fresh key for the same snapshot")
    func restoresWithFreshKey() async throws {
        let recorder = Recorder()
        let refetched = LockedFlag()
        let store = writingStore(recorder: recorder) { method, path in
            if path.hasSuffix("/snapshots/restore") {
                return (200, Self.disk(sizeGB: 10))
            }
            // The second list fetch hands out a new key for the same snapshot.
            if refetched.value {
                return (200, Self.snapshots.replacingOccurrences(of: "key-newest", with: "key-newest-renewed"))
            }
            refetched.value = true
            return (200, Self.snapshots)
        }
        await store.load()
        let shown = try #require(store.snapshots.first)

        await store.restore(shown)

        let restore = try #require(recorder.requests.last)
        #expect(restore.method == .post && restore.path.hasSuffix("/disks/dsk-1/snapshots/restore"))
        let body = try JSONSerialization.jsonObject(with: Data((restore.body ?? "").utf8)) as? [String: String]
        #expect(body == ["snapshotKey": "key-newest-renewed", "instanceId": "srv-1"])
        #expect(recorder.requests.count == 3)
        #expect(store.actionResult?.isFailure == false)
        #expect(store.restoringID == nil)
    }

    @Test("a snapshot that's gone by restore time is not restored")
    func restoreSkipsVanishedSnapshot() async throws {
        let recorder = Recorder()
        let refetched = LockedFlag()
        let store = writingStore(recorder: recorder) { _, _ in
            if refetched.value { return (200, "[]") }
            refetched.value = true
            return (200, Self.snapshots)
        }
        await store.load()
        let shown = try #require(store.snapshots.first)

        await store.restore(shown)

        #expect(!recorder.requests.contains { $0.path.hasSuffix("/restore") })
        #expect(store.actionResult?.isFailure == true)
        #expect(store.snapshots.isEmpty)
    }

    private nonisolated static let twoUndated = #"""
    [
      {"instanceId": "srv-1", "snapshotKey": "key-a"},
      {"instanceId": "srv-1", "snapshotKey": "key-b"}
    ]
    """#

    @Test("undated snapshots of one instance get distinct IDs")
    func undatedSnapshotsAreDistinct() async {
        let (store, _) = store { _ in (200, Self.twoUndated) }

        await store.load()

        #expect(Set(store.snapshots.map(\.id)).count == 2)
        #expect(Set(store.snapshots.map(\.matchID)).count == 2)
    }

    @Test("an undated snapshot whose key is gone is not swapped for another undated one")
    func undatedRestoreNeedsTheSameKey() async throws {
        let recorder = Recorder()
        let refetched = LockedFlag()
        let store = writingStore(recorder: recorder) { _, _ in
            if refetched.value { return (200, #"[{"instanceId": "srv-1", "snapshotKey": "key-b"}]"#) }
            refetched.value = true
            return (200, Self.twoUndated)
        }
        await store.load()
        let shown = try #require(store.snapshots.first { $0.key == "key-a" })

        await store.restore(shown)

        #expect(!recorder.requests.contains { $0.path.hasSuffix("/restore") })
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("an undated snapshot still listed under its key is restored")
    func undatedRestoreWithSameKey() async throws {
        let recorder = Recorder()
        let store = writingStore(recorder: recorder) { _, path in
            path.hasSuffix("/restore") ? (200, Self.disk(sizeGB: 10)) : (200, Self.twoUndated)
        }
        await store.load()

        await store.restore(try #require(store.snapshots.first { $0.key == "key-b" }))

        let restore = try #require(recorder.requests.last)
        let body = try JSONSerialization.jsonObject(with: Data((restore.body ?? "").utf8)) as? [String: String]
        #expect(body == ["snapshotKey": "key-b", "instanceId": "srv-1"])
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("two snapshots matching the same time and instance are not guessed between")
    func ambiguousRestoreIsRefused() async throws {
        let recorder = Recorder()
        let refetched = LockedFlag()
        let dated = #"{"createdAt": "2026-11-21T00:10:00Z", "instanceId": "srv-1", "snapshotKey": "%@"}"#
        let store = writingStore(recorder: recorder) { _, _ in
            if refetched.value {
                return (200, "[" + String(format: dated, "key-x") + "," + String(format: dated, "key-y") + "]")
            }
            refetched.value = true
            return (200, "[" + String(format: dated, "key-x") + "]")
        }
        await store.load()

        await store.restore(try #require(store.snapshots.first))

        #expect(!recorder.requests.contains { $0.path.hasSuffix("/restore") })
        #expect(store.actionResult?.isFailure == true)
        // Both are listed, and each row still has its own identity.
        #expect(store.snapshots.count == 2)
        #expect(Set(store.snapshots.map(\.id)).count == 2)
    }

    @Test("a key Render lists twice is shown once")
    func repeatedKeyIsShownOnce() async {
        let (store, _) = store { _ in
            (200, #"[{"instanceId": "srv-1", "snapshotKey": "key-a"}, {"instanceId": "srv-1", "snapshotKey": "key-a"}]"#)
        }

        await store.load()

        #expect(store.snapshots.map(\.key) == ["key-a"])
    }

    @Test("the restore prompt names the instance whose disk it overwrites")
    func restoreTitleNamesInstance() {
        let scaled = DiskStore.Snapshot(key: "k1", createdAt: nil, instanceID: "srv-abc-xyz12")
        #expect(scaled.instanceLabel == "Instance srv-abc-xyz12")
        #expect(scaled.restoreTitle(diskName: "data") == "Restore data on instance srv-abc-xyz12 from this snapshot?")

        let dated = DiskStore.Snapshot(key: "k2", createdAt: Date(timeIntervalSince1970: 0), instanceID: "srv-abc-xyz12")
        #expect(dated.restoreTitle(diskName: "data").contains("on instance srv-abc-xyz12 to "))

        let single = DiskStore.Snapshot(key: "k3", createdAt: nil, instanceID: nil)
        #expect(single.instanceLabel == nil)
        #expect(single.restoreTitle(diskName: "data") == "Restore data from this snapshot?")
        #expect(DiskStore.Snapshot(key: "k4", createdAt: nil, instanceID: "").instanceLabel == nil)
    }

    @Test("a failed restore is reported")
    func restoreFails() async throws {
        let store = writingStore(recorder: Recorder()) { _, path in
            path.hasSuffix("/restore") ? (500, #"{"message":"boom"}"#) : (200, Self.snapshots)
        }
        await store.load()

        await store.restore(try #require(store.snapshots.first))

        #expect(store.actionResult?.isFailure == true)
        #expect(store.restoringID == nil)
    }

    // MARK: - Deleting

    @Test("deleting sends one DELETE for the disk and reports it gone")
    func deletes() async throws {
        let recorder = Recorder()
        let store = writingStore(recorder: recorder) { method, path in
            method == .delete && path.hasSuffix("/disks/dsk-1") ? (204, "") : (500, "{}")
        }

        #expect(await store.delete())

        #expect(recorder.requests.map(\.method) == [.delete])
        #expect(store.actionResult == nil)
        #expect(!store.isDeleting)
    }

    @Test("a disk that's already gone counts as deleted")
    func deleteNotFound() async {
        let store = writingStore(recorder: Recorder()) { _, _ in (404, #"{"message":"not found"}"#) }

        #expect(await store.delete())
        #expect(store.actionResult == nil)
    }

    @Test("a refused delete keeps the screen open and says why")
    func deleteFails() async {
        let store = writingStore(recorder: Recorder()) { _, _ in (500, #"{"message":"boom"}"#) }

        #expect(await store.delete() == false)
        #expect(store.actionResult?.isFailure == true)
        #expect(!store.isDeleting)
    }

    @Test("nothing is deleted while a resize is running")
    func deleteWaitsForOtherWrites() async throws {
        let recorder = Recorder()
        let gate = AsyncStream<Void>.makeStream()
        let transport = StubTransport { request, _, _ in
            recorder.append(.init(method: request.method, path: request.path ?? "", body: nil))
            if request.method == .patch {
                for await _ in gate.stream { break }
            }
            var response = HTTPResponse(status: .init(code: request.method == .patch ? 200 : 204))
            response.headerFields = [.contentType: "application/json"]
            return (response, HTTPBody(request.method == .patch ? Self.disk(sizeGB: 20) : ""))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("k"), retryPolicy: .none, transport: transport)
        let store = DiskStore(client: client, diskID: "dsk-1", sizeGB: 10)

        let resize = Task { await store.resize(to: 20) }
        while !store.isResizing { await Task.yield() }

        #expect(await store.delete() == false)
        gate.continuation.yield()
        gate.continuation.finish()
        await resize.value
        #expect(recorder.requests.map(\.method) == [.patch])
    }
}

@MainActor
@Suite("NewDiskStore")
struct NewDiskStoreTests {
    private func store(
        recorder: Recorder,
        _ route: @escaping @Sendable (HTTPRequest.Method, String) -> (status: Int, body: String)
    ) -> NewDiskStore {
        NewDiskStore(client: writingClient(recorder: recorder, route), serviceID: "srv-1")
    }

    @Test("the form checks the rules Render enforces before anything is sent")
    func validation() {
        let store = store(recorder: Recorder()) { _, _ in (500, "{}") }
        #expect(store.validationMessage == "Enter a name.")
        store.name = "  data "
        store.sizeText = ""
        #expect(store.validationMessage == "Enter a size in GB.")
        store.sizeText = "0"
        #expect(store.validationMessage == "A disk must be at least 1 GB.")
        store.sizeText = "5"
        #expect(store.validationMessage == "Enter a mount path.")
        store.mountPath = "var/data"
        #expect(store.validationMessage == "The mount path must start with /.")
        store.mountPath = " /var/data "
        #expect(store.validationMessage == nil)
    }

    @Test("adding POSTs the trimmed fields for this service and returns the new disk's name")
    func creates() async throws {
        let recorder = Recorder()
        let store = store(recorder: recorder) { method, path in
            method == .post && path.hasSuffix("/disks")
                ? (201, #"{"id":"dsk-2","name":"data","sizeGB":5,"mountPath":"/var/data","serviceId":"srv-1","createdAt":"2026-11-25T00:00:00Z","updatedAt":"2026-11-25T00:00:00Z"}"#)
                : (404, "{}")
        }
        store.name = " data "
        store.sizeText = "5"
        store.mountPath = " /var/data"

        #expect(await store.create() == "data")

        let request = try #require(recorder.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: Data((request.body ?? "").utf8)) as? [String: Any])
        #expect(body["name"] as? String == "data")
        #expect(body["sizeGB"] as? Int == 5)
        #expect(body["mountPath"] as? String == "/var/data")
        #expect(body["serviceId"] as? String == "srv-1")
        #expect(store.error == nil && !store.isCreating)
    }

    @Test("Render's reason is shown when it refuses, and nothing is reported as added")
    func refused() async {
        let store = store(recorder: Recorder()) { _, _ in (400, #"{"message":"disk already exists"}"#) }
        store.name = "data"
        store.mountPath = "/data"

        #expect(await store.create() == nil)
        #expect(store.error?.contains("Disk already exists.") == true)
    }

    @Test("an invalid form is never sent")
    func invalidNotSent() async {
        let recorder = Recorder()
        let store = store(recorder: recorder) { _, _ in (201, "{}") }
        store.name = "data"
        store.mountPath = "data"

        #expect(await store.create() == nil)
        #expect(recorder.requests.isEmpty)
    }
}

@Suite("Add Disk availability")
struct AddDiskAvailabilityTests {
    private func details(type: String, diskSizeGB: Int? = nil, plan: String = "starter") throws -> ServiceDetails {
        let json = Fixtures.serviceJSON(
            type: type,
            details: Fixtures.serviceDetailsJSON(for: type, diskSizeGB: diskSizeGB)
                .replacingOccurrences(of: #""plan":"starter""#, with: #""plan":"\#(plan)""#)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ServiceDetails(try decoder.decode(Components.Schemas.Service.self, from: Data(json.utf8)))
    }

    @Test("offered for paid web services, private services and workers with no disk")
    func offered() throws {
        for type in ["web_service", "private_service", "background_worker"] {
            #expect(try details(type: type).canAddDisk, "\(type)")
        }
    }

    @Test("not offered with a disk already, on a free instance, or for sites and cron jobs")
    func notOffered() throws {
        #expect(try !details(type: "web_service", diskSizeGB: 1).canAddDisk)
        #expect(try !details(type: "web_service", plan: "free").canAddDisk)
        #expect(try !details(type: "static_site").canAddDisk)
        #expect(try !details(type: "cron_job").canAddDisk)
    }
}

/// A client whose stub records the method and request body of each write.
private func writingClient(
    recorder: Recorder,
    _ route: @escaping @Sendable (HTTPRequest.Method, String) -> (status: Int, body: String)
) -> RenderClient {
    let transport = StubTransport { request, body, _ in
        let path = request.path ?? ""
        var sent: String?
        if let body {
            let data = try await Data(collecting: body, upTo: 1 << 16)
            sent = String(decoding: data, as: UTF8.self)
        }
        recorder.append(.init(method: request.method, path: path, body: sent))
        let answer = route(request.method, path)
        var response = HTTPResponse(status: .init(code: answer.status))
        response.headerFields = [.contentType: "application/json"]
        return (response, HTTPBody(answer.body))
    }
    return RenderClient(
        apiKeyProvider: StaticAPIKeyProvider("test-key"),
        retryPolicy: .none,
        transport: transport
    )
}

/// Every request the writing store sent, with its body.
private final class Recorder: @unchecked Sendable {
    struct Request {
        let method: HTTPRequest.Method
        let path: String
        let body: String?
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    var requests: [Request] { lock.withLock { _requests } }
    func append(_ request: Request) { lock.withLock { _requests.append(request) } }
}
