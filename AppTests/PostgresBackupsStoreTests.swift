import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Point-in-time recovery and exports for one Postgres database.
@MainActor
@Suite("PostgresBackupsStore")
struct PostgresBackupsStoreTests {
    /// What Render answers, changeable mid-test, plus what the store sent it.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _recovery: (Int, String) = (200, #"{"recoveryStatus":"AVAILABLE","startsAt":"2026-11-14T04:00:00Z"}"#)
        private var _exports: (Int, String) = (200, "[]")
        private var _createExport: (Int, String) = (202, "")
        private var _recover: (Int, String) = (200, Fixtures.postgresJSON(id: "dpg-new", name: "db-restore", status: "creating"))
        private var _recoverBody: Data?
        private var _exportsGate: Gate?
        private var _now = PostgresBackupsStoreTests.clock

        /// Holds the next exports read, after it has taken its answer, until the gate opens. One use.
        func holdNextExportsRead(at gate: Gate) {
            lock.withLock { _exportsGate = gate }
        }

        func takeExportsGate() -> Gate? {
            lock.withLock {
                defer { _exportsGate = nil }
                return _exportsGate
            }
        }

        var recovery: (Int, String) {
            get { lock.withLock { _recovery } }
            set { lock.withLock { _recovery = newValue } }
        }

        var exports: (Int, String) {
            get { lock.withLock { _exports } }
            set { lock.withLock { _exports = newValue } }
        }

        var createExport: (Int, String) {
            get { lock.withLock { _createExport } }
            set { lock.withLock { _createExport = newValue } }
        }

        var recover: (Int, String) {
            get { lock.withLock { _recover } }
            set { lock.withLock { _recover = newValue } }
        }

        var recoverBody: Data? {
            get { lock.withLock { _recoverBody } }
            set { lock.withLock { _recoverBody = newValue } }
        }

        var now: Date {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
    }

    /// Lets a test hold a request in flight and know when it got there.
    private actor Gate {
        private var entered = false
        private var isOpen = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiter: CheckedContinuation<Void, Never>?

        func hold() async {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters = []
            guard !isOpen else { return }
            await withCheckedContinuation { openWaiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func open() {
            isOpen = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    /// 05:00Z on the day of the recovery window above, which opens at 04:00Z.
    private nonisolated static let clock = Date(timeIntervalSince1970: 1_794_632_400)

    private nonisolated static func exportsJSON(_ exports: [(id: String, at: String, url: String?)]) -> String {
        let items = exports.map { export in
            let url = export.url.map { #","url":"\#($0)""# } ?? ""
            return #"{"id":"\#(export.id)","createdAt":"\#(export.at)"\#(url)}"#
        }
        return "[\(items.joined(separator: ","))]"
    }

    private func store(_ backend: Backend) -> (PostgresBackupsStore, StubTransport) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            let answer: (Int, String)
            switch (request.method, path) {
            case (.get, let p) where p.hasSuffix("/recovery"): answer = backend.recovery
            case (.post, let p) where p.hasSuffix("/recovery"):
                if let body { backend.recoverBody = try await Data(collecting: body, upTo: 64 * 1024) }
                answer = backend.recover
            case (.get, let p) where p.hasSuffix("/export"):
                // Taken before any hold, so a held read answers with the list as it was when sent.
                answer = backend.exports
                if let gate = backend.takeExportsGate() { await gate.hold() }
            case (.post, let p) where p.hasSuffix("/export"): answer = backend.createExport
            default: answer = (404, #"{"message":"not found"}"#)
            }
            var response = HTTPResponse(status: .init(code: answer.0))
            response.headerFields = [.contentType: "application/json"]
            return (response, answer.1.isEmpty ? nil : HTTPBody(answer.1))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        // A long poll interval: the tests drive reloads themselves.
        let store = PostgresBackupsStore(client: client, postgresID: "dpg-1", pollInterval: .seconds(3600), now: { backend.now })
        return (store, transport)
    }

    // MARK: - Recovery status

    @Test("recovery statuses map, and one this version doesn't know reads as not available")
    func recoveryStatusMapping() {
        let startsAt = Self.clock.addingTimeInterval(-3600)
        #expect(PostgresRecovery(rawStatus: "AVAILABLE", startsAt: startsAt).status == .available)
        #expect(PostgresRecovery(rawStatus: "BACKUP_NOT_READY", startsAt: nil).status == .backupNotReady)
        #expect(PostgresRecovery(rawStatus: "NOT_AVAILABLE", startsAt: nil).status == .notAvailable)
        #expect(PostgresRecovery(rawStatus: "SOMETHING_NEW", startsAt: startsAt).status == .notAvailable)
    }

    @Test("the recovery window runs from startsAt to now, and only while recovery is available")
    func recoveryWindow() {
        let startsAt = Self.clock.addingTimeInterval(-3600)
        #expect(PostgresRecovery(rawStatus: "AVAILABLE", startsAt: startsAt).window(now: Self.clock) == startsAt...Self.clock)
        #expect(PostgresRecovery(rawStatus: "AVAILABLE", startsAt: nil).window(now: Self.clock) == nil)
        #expect(PostgresRecovery(rawStatus: "BACKUP_NOT_READY", startsAt: startsAt).window(now: Self.clock) == nil)
    }

    @Test("a restore needs a name and a time inside the window")
    func restoreValidation() {
        let window = Self.clock.addingTimeInterval(-3600)...Self.clock
        let valid = PostgresRestoreRequest(name: " db-restore ", time: Self.clock.addingTimeInterval(-60))
        #expect(valid.validationMessage(window: window) == nil)
        #expect(valid.trimmedName == "db-restore")

        var blank = valid
        blank.name = "   "
        #expect(blank.validationMessage(window: window) != nil)

        var tooEarly = valid
        tooEarly.time = window.lowerBound.addingTimeInterval(-1)
        #expect(tooEarly.validationMessage(window: window) != nil)

        #expect(valid.validationMessage(window: nil) != nil)
    }

    // MARK: - Loading

    @Test("load maps recovery and lists exports newest first")
    func loadMapsBoth() async throws {
        let backend = Backend()
        backend.exports = (200, Self.exportsJSON([
            (id: "exp-old", at: "2026-11-13T05:00:00Z", url: "https://exports.example/old.dir.tar.gz"),
            (id: "exp-new", at: "2026-11-14T04:30:00Z", url: nil),
        ]))
        let (store, _) = store(backend)

        await store.load()

        #expect(store.recovery?.status == .available)
        #expect(store.recoveryWindow?.upperBound == Self.clock)
        #expect(store.exports.map(\.id) == ["exp-new", "exp-old"])
        #expect(store.exports[0].url == nil)
        #expect(store.exports[1].url?.host() == "exports.example")
    }

    @Test("an exports failure doesn't hide recovery, and a recovery failure doesn't hide exports")
    func failuresAreIsolated() async {
        let backend = Backend()
        backend.exports = (500, #"{"message":"boom"}"#)
        let (store, _) = store(backend)

        await store.load()
        #expect(store.recovery?.status == .available)
        #expect(store.exportsErrorMessage != nil)
        #expect(store.recoveryErrorMessage == nil)

        backend.exports = (200, Self.exportsJSON([(id: "exp-1", at: "2026-11-14T04:30:00Z", url: nil)]))
        backend.recovery = (500, #"{"message":"boom"}"#)
        await store.refresh()
        #expect(store.exports.map(\.id) == ["exp-1"])
        #expect(store.exportsErrorMessage == nil)
        #expect(store.recoveryErrorMessage != nil)
    }

    // MARK: - Exports

    @Test("a requested export is watched until a new export appears")
    func exportWatchedUntilListed() async {
        let backend = Backend()
        backend.exports = (200, Self.exportsJSON([(id: "exp-old", at: "2026-11-13T05:00:00Z", url: nil)]))
        let (store, transport) = store(backend)
        await store.load()
        defer { store.stopPolling() }

        await store.requestExport()

        #expect(transport.requests.contains { $0.method == .post && ($0.path ?? "").hasSuffix("/postgres/dpg-1/export") })
        #expect(store.isWatchingForExport)
        #expect(store.actionResult?.isFailure == false)

        await store.refresh()
        #expect(store.isWatchingForExport, "the list hasn't changed yet")

        backend.exports = (200, Self.exportsJSON([
            (id: "exp-old", at: "2026-11-13T05:00:00Z", url: nil),
            (id: "exp-new", at: "2026-11-14T05:01:00Z", url: "https://exports.example/new"),
        ]))
        await store.refresh()
        #expect(!store.isWatchingForExport)
        #expect(store.exports.first?.id == "exp-new")
    }

    @Test("a new export listed before its download link is ready stays watched until the link arrives")
    func exportWatchedUntilDownloadable() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()
        await store.requestExport()
        defer { store.stopPolling() }

        backend.exports = (200, Self.exportsJSON([(id: "exp-new", at: "2026-11-14T05:01:00Z", url: nil)]))
        await store.refresh()
        #expect(store.isWatchingForExport, "listed but still being written")
        #expect(store.exports.first?.url == nil)

        backend.exports = (200, Self.exportsJSON([(id: "exp-new", at: "2026-11-14T05:01:00Z", url: "https://exports.example/new")]))
        await store.refresh()
        #expect(!store.isWatchingForExport)
        #expect(store.exports.first?.url != nil)
    }

    @Test("an older reload that answers last doesn't replace a newer one's exports")
    func olderReloadIgnored() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()
        await store.requestExport()
        defer { store.stopPolling() }

        // The older read leaves with an empty list and is held until the newer one has finished.
        let gate = Gate()
        backend.holdNextExportsRead(at: gate)
        let older = Task { await store.refresh() }
        await gate.waitUntilEntered()

        backend.exports = (200, Self.exportsJSON([(id: "exp-new", at: "2026-11-14T05:01:00Z", url: "https://exports.example/new")]))
        await store.refresh()
        #expect(!store.isWatchingForExport)

        await gate.open()
        await older.value
        #expect(store.exports.map(\.id) == ["exp-new"], "the older, empty list must not win")
        #expect(!store.isWatchingForExport)
    }

    @Test("an export that never appears stops being watched after the limit")
    func exportWatchExpires() async {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()
        await store.requestExport()
        defer { store.stopPolling() }

        backend.now = Self.clock.addingTimeInterval(PostgresBackupsStore.exportWatchLimit - 1)
        await store.refresh()
        #expect(store.isWatchingForExport)

        backend.now = Self.clock.addingTimeInterval(PostgresBackupsStore.exportWatchLimit + 1)
        await store.refresh()
        #expect(!store.isWatchingForExport)
    }

    @Test("an export Render refuses shows Render's reason and isn't watched")
    func exportRefused() async {
        let backend = Backend()
        // What Render answered live while an export was already running.
        backend.createExport = (409, #"{"message":"DB already has running backup"}"#)
        let (store, _) = store(backend)
        await store.load()

        await store.requestExport()

        #expect(!store.isWatchingForExport)
        #expect(store.actionResult?.isFailure == true)
        #expect(store.actionResult?.message.contains("already has running backup") == true)
    }

    // MARK: - Restore

    @Test("a restore sends the name and time, and keeps the new database")
    func restoreSendsRequest() async throws {
        let backend = Backend()
        let (store, _) = store(backend)
        await store.load()
        let time = Self.clock.addingTimeInterval(-600)

        await store.restore(PostgresRestoreRequest(name: " db-restore ", time: time))

        let body = try #require(backend.recoverBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["restoreName"] as? String == "db-restore")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect((json["restoreTime"] as? String).flatMap(formatter.date(from:)) == time)
        #expect(json.count == 2, "plan, environment and Datadog settings default to the original's")
        #expect(store.restoredDatabase?.id == "dpg-new")
        #expect(store.restoredDatabase?.name == "db-restore")
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("a restore outside the window isn't sent")
    func restoreOutsideWindowNotSent() async {
        let backend = Backend()
        let (store, transport) = store(backend)
        await store.load()

        await store.restore(PostgresRestoreRequest(name: "db-restore", time: Self.clock.addingTimeInterval(-2 * 3600)))

        #expect(!transport.requests.contains { $0.method == .post })
        #expect(store.restoredDatabase == nil)
    }

    @Test("a restore Render refuses shows Render's reason")
    func restoreRefused() async {
        let backend = Backend()
        backend.recover = (400, #"{"message":"No valid recovery window exists. Backup is not ready."}"#)
        let (store, _) = store(backend)
        await store.load()

        await store.restore(PostgresRestoreRequest(name: "db-restore", time: Self.clock.addingTimeInterval(-60)))

        #expect(store.restoredDatabase == nil)
        #expect(store.actionResult?.isFailure == true)
        #expect(store.actionResult?.message.contains("No valid recovery window") == true)
    }
}
