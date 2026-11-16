import Foundation
import Observation
import RenderAPI

/// Point-in-time recovery availability from `GET /postgres/{id}/recovery`.
struct PostgresRecovery: Hashable, Sendable {
    enum Status: Hashable, Sendable {
        case available
        /// The database is new and its first base backup hasn't finished. Render answers a restore
        /// request with 400 "No valid recovery window exists" until it has.
        case backupNotReady
        case notAvailable
    }

    let status: Status
    /// The earliest moment a restore can target. Only meaningful while `status == .available`.
    let startsAt: Date?

    /// The status arrives as free text (see `Scripts/freeform-recovery-status.py`). A value this
    /// version doesn't know reads as `.notAvailable`: that hides the restore button rather than
    /// offering a restore Render might refuse.
    init(rawStatus: String, startsAt: Date?) {
        switch rawStatus {
        case "AVAILABLE": status = .available
        case "BACKUP_NOT_READY": status = .backupNotReady
        default: status = .notAvailable
        }
        self.startsAt = startsAt
    }

    /// The times a restore can target, ending at `now`. Nil when no restore is possible.
    func window(now: Date) -> ClosedRange<Date>? {
        guard status == .available, let startsAt, startsAt <= now else { return nil }
        return startsAt...now
    }
}

/// One logical export from `GET /postgres/{id}/export`.
struct PostgresExport: Identifiable, Hashable, Sendable {
    let id: String
    let createdAt: Date
    /// Download link. Render leaves it out while an export is still being written.
    let url: URL?
}

/// What the restore sheet submits. Restoring never touches the original database: Render creates a
/// new one, on the same plan, holding the data as it was at `time`.
struct PostgresRestoreRequest: Hashable, Sendable {
    var name: String
    var time: Date

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the request can't be sent yet, or nil when it can.
    func validationMessage(window: ClosedRange<Date>?) -> String? {
        guard let window else { return "Point-in-time recovery isn't available for this database." }
        if trimmedName.isEmpty { return "Enter a name for the new database." }
        if !window.contains(time) { return "Choose a time within the recovery window." }
        return nil
    }
}

/// Backs the Backups screen for one Postgres database: point-in-time recovery and logical exports.
///
/// Both requests Render accepts are asynchronous. A restore answers with the *new* database, which
/// is still being created; an export answers 202 with no body and appears in the export list some
/// minutes later. So after requesting an export the store polls the list until a new entry shows
/// up, and gives up after `exportWatchLimit`.
@MainActor
@Observable
final class PostgresBackupsStore {
    private(set) var recovery: PostgresRecovery?
    private(set) var recoveryErrorMessage: String?
    /// Newest first.
    private(set) var exports: [PostgresExport] = []
    private(set) var exportsErrorMessage: String?
    private(set) var hasLoaded = false
    private(set) var isRequestingExport = false
    private(set) var isRestoring = false
    /// Set from a successful export request until a new export appears in the list.
    private(set) var exportRequestedAt: Date?
    /// The database a successful restore created, so the screen can offer to open it.
    private(set) var restoredDatabase: PostgresDetailModel?
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    /// How long to keep watching for a requested export before assuming it won't show up. Exports
    /// of a small database took several minutes live, so this is generous.
    static let exportWatchLimit: TimeInterval = 30 * 60

    private let client: RenderClient
    let postgresID: String
    private let pollInterval: Duration
    private let now: @Sendable () -> Date
    private var pollTask: Task<Void, Never>?
    /// Export IDs already listed when the export was requested. A new ID is how the store knows the
    /// request finished. Comparing timestamps instead would depend on Render's clock matching ours.
    private var exportIDsAtRequest: Set<String> = []

    init(
        client: RenderClient,
        postgresID: String,
        pollInterval: Duration = .seconds(15),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.postgresID = postgresID
        self.pollInterval = pollInterval
        self.now = now
    }

    var isWatchingForExport: Bool { exportRequestedAt != nil }

    /// The times the restore sheet may offer, ending now.
    var recoveryWindow: ClosedRange<Date>? { recovery?.window(now: now()) }

    func load() async {
        await reload()
        hasLoaded = true
        startPollingIfNeeded()
    }

    func refresh() async {
        await reload()
        startPollingIfNeeded()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func dismissActionResult() {
        actionResult = nil
    }

    /// Asks Render to write a new export, then watches the list for it.
    func requestExport() async {
        guard !isRequestingExport, !isWatchingForExport else { return }
        isRequestingExport = true
        actionResult = nil
        defer { isRequestingExport = false }

        do {
            _ = try await client.api.createPostgresExport(path: .init(postgresId: postgresID)).accepted
            exportIDsAtRequest = Set(exports.map(\.id))
            exportRequestedAt = now()
            actionResult = ActionResult(
                message: "Export requested. It appears here when Render finishes writing it.",
                isFailure: false
            )
        } catch {
            // Render answers 409 "DB already has running backup" while another export is going,
            // and its sentence is the clearest thing to show.
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
        }
        startPollingIfNeeded()
    }

    /// Creates a new database from this one as it was at `request.time`. The original is untouched.
    func restore(_ request: PostgresRestoreRequest) async {
        guard !isRestoring, request.validationMessage(window: recoveryWindow) == nil else { return }
        isRestoring = true
        actionResult = nil
        defer { isRestoring = false }

        do {
            let detail = try await client.api.recoverPostgres(
                path: .init(postgresId: postgresID),
                body: .json(.init(restoreName: request.trimmedName, restoreTime: request.time))
            ).ok.body.json
            let created = PostgresDetailModel(detail)
            restoredDatabase = created
            actionResult = ActionResult(
                message: "Restore started. Render is creating \(created.name).",
                isFailure: false
            )
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
        }
    }

    // MARK: - Loading

    private func reload() async {
        let client = client
        let postgresID = postgresID
        // Independent, and each section reports its own failure: exports are still worth showing
        // when recovery info can't be read, and the other way round.
        async let recoveryAttempt: Result<PostgresRecovery, any Error> = {
            do {
                let info = try await client.api
                    .retrievePostgresRecoveryInfo(path: .init(postgresId: postgresID))
                    .ok.body.json
                return .success(PostgresRecovery(rawStatus: info.recoveryStatus, startsAt: info.startsAt))
            } catch {
                return .failure(error)
            }
        }()

        do {
            let listed = try await client.api
                .listPostgresExport(path: .init(postgresId: postgresID))
                .ok.body.json
            exports = listed
                .map { PostgresExport(id: $0.id, createdAt: $0.createdAt, url: $0.url.flatMap(URL.init(string:))) }
                .sorted { $0.createdAt > $1.createdAt }
            exportsErrorMessage = nil
            if isWatchingForExport, exports.contains(where: { !exportIDsAtRequest.contains($0.id) }) {
                exportRequestedAt = nil
            }
        } catch {
            exportsErrorMessage = Self.message(for: error)
        }

        switch await recoveryAttempt {
        case .success(let recovery):
            self.recovery = recovery
            recoveryErrorMessage = nil
        case .failure(let error):
            recoveryErrorMessage = Self.message(for: error)
        }

        if let requestedAt = exportRequestedAt, now().timeIntervalSince(requestedAt) >= Self.exportWatchLimit {
            exportRequestedAt = nil
        }
    }

    /// Polls only while an export is pending, so an idle screen costs no requests.
    private func startPollingIfNeeded() {
        guard isWatchingForExport else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }

        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.reload()
                if !self.isWatchingForExport {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
