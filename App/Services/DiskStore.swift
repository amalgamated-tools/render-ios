import Foundation
import Observation
import RenderAPI

/// A service's disk, the snapshots Render has taken of it, and the writes a phone can make: growing
/// the disk, restoring a snapshot, and deleting the disk.
///
/// The disk itself comes from the service details the detail screen already loaded, so only the
/// snapshot list is fetched here. The size is kept locally after that so a resize shows straight away.
@MainActor
@Observable
final class DiskStore {
    struct Snapshot: Identifiable, Hashable, Sendable {
        /// The row's identity within one fetch: the restore key, which `snapshots(from:)` keeps unique.
        /// It isn't stable across fetches (keys expire after 24 hours and may be reissued), so it
        /// isn't used to find a snapshot again; see `matchID`.
        var id: String { key }

        /// Finds the same snapshot in a later fetch: when and where it was taken. An undated snapshot
        /// has only its key to tell it apart (instance alone would match every undated snapshot of
        /// an instance), so it can only be found again while a fresh fetch still returns that key.
        /// Two snapshots can share a match ID; a restore refuses to pick between them.
        var matchID: String {
            guard let createdAt else { return "key|\(key)" }
            return "\(instanceID ?? "")|\(createdAt.timeIntervalSince1970)"
        }
        /// Render's opaque restore key, as of the last fetch.
        let key: String
        let createdAt: Date?
        /// The instance the snapshot was taken from.
        let instanceID: String?

        /// Which instance's disk a restore overwrites. On a scaled service each instance has its own
        /// disk and snapshots, often taken at the same time, so the date alone can't tell them apart.
        var instanceLabel: String? {
            guard let instanceID, !instanceID.isEmpty else { return nil }
            return "Instance \(instanceID)"
        }

        /// The restore confirmation's title, naming the instance whenever Render reports one.
        func restoreTitle(diskName: String) -> String {
            let when = createdAt.map { "to \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "from this snapshot"
            guard let instanceLabel else { return "Restore \(diskName) \(when)?" }
            return "Restore \(diskName) on \(instanceLabel.lowercased()) \(when)?"
        }
    }

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private(set) var snapshots: [Snapshot] = []
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    private(set) var sizeGB: Int
    private(set) var isResizing = false
    /// The `matchID` of the snapshot being restored, so its row can show progress even after the
    /// fresh fetch renews its key.
    private(set) var restoringID: String?
    private(set) var isDeleting = false
    private(set) var actionResult: ActionResult?

    var isWriting: Bool { isResizing || restoringID != nil || isDeleting }

    private let client: RenderClient
    let diskID: String

    init(client: RenderClient, diskID: String, sizeGB: Int) {
        self.client = client
        self.diskID = diskID
        self.sizeGB = sizeGB
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            snapshots = try await fetchSnapshots()
            error = nil
            hasLoaded = true
        } catch {
            self.error = Self.message(for: error)
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    // MARK: - Writing

    /// Why `newSize` can't be sent, or nil if it can. Render only grows disks.
    func resizeValidationMessage(_ newSize: Int?) -> String? {
        guard let newSize else { return "Enter a size in GB." }
        return newSize > sizeGB ? nil : "A disk can only grow. Enter more than \(sizeGB) GB."
    }

    func resize(to newSize: Int) async {
        guard !isWriting, resizeValidationMessage(newSize) == nil else { return }
        isResizing = true
        actionResult = nil
        defer { isResizing = false }

        do {
            let disk = try await client.api.updateDisk(
                path: .init(diskId: diskID),
                body: .json(.init(sizeGB: newSize))
            ).ok.body.json
            sizeGB = disk.sizeGB
            actionResult = ActionResult(message: "The disk is now \(disk.sizeGB) GB.", isFailure: false)
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
        }
    }

    /// Overwrites the disk with `snapshot`.
    ///
    /// The list is fetched again first, because the key on screen may have expired; the snapshot is
    /// matched by `Snapshot.matchID`. If it's no longer listed, or more than one snapshot
    /// matches, nothing is restored: a restore overwrites the disk, so a guess isn't good enough.
    func restore(_ snapshot: Snapshot) async {
        guard !isWriting else { return }
        restoringID = snapshot.matchID
        actionResult = nil
        defer { restoringID = nil }

        do {
            let fresh = try await fetchSnapshots()
            snapshots = fresh
            let matches = fresh.filter { $0.matchID == snapshot.matchID }
            guard matches.count == 1, let current = matches.first else {
                actionResult = ActionResult(
                    message: "That snapshot is no longer available. Nothing was restored.",
                    isFailure: true
                )
                return
            }
            _ = try await client.api.restoreSnapshot(
                path: .init(diskId: diskID),
                body: .json(.init(snapshotKey: current.key, instanceId: current.instanceID))
            ).ok
            let when = current.createdAt.map { " from \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
            actionResult = ActionResult(
                message: "Restoring the snapshot\(when). Render may redeploy the service.",
                isFailure: false
            )
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
        }
    }

    /// Deletes the disk and everything on it. Returns true once it's gone, so the screen can close.
    ///
    /// A 404 or 410 counts as gone: most likely a retried DELETE whose first answer was lost, or a
    /// delete made elsewhere, and the spec documents 410 for a disk or service that's already gone.
    /// Either way the disk no longer exists, as asked.
    func delete() async -> Bool {
        guard !isWriting else { return false }
        isDeleting = true
        actionResult = nil
        defer { isDeleting = false }

        do {
            try await client.api.deleteDisk(path: .init(diskId: diskID)).expectSuccess()
            return true
        } catch {
            switch RenderError.wrapping(error) {
            case .notFound, .client(statusCode: 410, _): return true
            default: break
            }
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    // MARK: - Helpers

    private func fetchSnapshots() async throws -> [Snapshot] {
        let fetched = try await client.api
            .listSnapshots(path: .init(diskId: diskID))
            .ok.body.json
        return Self.snapshots(from: fetched)
    }

    /// Newest first, since "how recent is my last snapshot?" is the question. A snapshot without a
    /// key can't be restored, so it's dropped, as is a repeat of a key already listed; one without a
    /// date sorts last.
    nonisolated static func snapshots(from payload: [Components.Schemas.DiskSnapshot]) -> [Snapshot] {
        var seen = Set<String>()
        return payload
            .compactMap { item in
                item.snapshotKey.map { Snapshot(key: $0, createdAt: item.createdAt, instanceID: item.instanceId) }
            }
            .filter { seen.insert($0.key).inserted }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
