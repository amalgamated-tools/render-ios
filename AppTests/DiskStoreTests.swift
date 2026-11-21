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
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            retryPolicy: .none,
            transport: transport
        )
        return DiskStore(client: client, diskID: "dsk-1", sizeGB: 10)
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
