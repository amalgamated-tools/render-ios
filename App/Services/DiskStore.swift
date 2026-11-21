import Foundation
import Observation
import RenderAPI

/// A service's disk, the snapshots Render has taken of it, and the two writes a phone can make:
/// growing the disk and restoring a snapshot.
///
/// The disk itself comes from the service details the detail screen already loaded, so only the
/// snapshot list is fetched here. The size is kept locally after that so a resize shows straight away.
@MainActor
@Observable
final class DiskStore {
    struct Snapshot: Identifiable, Hashable, Sendable {
        /// When and where it was taken. Not the restore key: keys expire after 24 hours and may differ
        /// between fetches, so they can't identify a snapshot across reloads.
        var id: String { "\(instanceID ?? "")|\(createdAt?.timeIntervalSince1970 ?? 0)" }
        /// Render's opaque restore key, as of the last fetch.
        let key: String
        let createdAt: Date?
        /// The instance the snapshot was taken from.
        let instanceID: String?
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
    /// The snapshot being restored, so its row can show progress.
    private(set) var restoringID: Snapshot.ID?
    private(set) var actionResult: ActionResult?

    var isWriting: Bool { isResizing || restoringID != nil }

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
    /// matched by its time and instance. If it's no longer listed, nothing is restored.
    func restore(_ snapshot: Snapshot) async {
        guard !isWriting else { return }
        restoringID = snapshot.id
        actionResult = nil
        defer { restoringID = nil }

        do {
            let fresh = try await fetchSnapshots()
            snapshots = fresh
            guard let current = fresh.first(where: { $0.id == snapshot.id }) else {
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

    // MARK: - Helpers

    private func fetchSnapshots() async throws -> [Snapshot] {
        let fetched = try await client.api
            .listSnapshots(path: .init(diskId: diskID))
            .ok.body.json
        return Self.snapshots(from: fetched)
    }

    /// Newest first, since "how recent is my last snapshot?" is the question. A snapshot without a
    /// key can't be restored, so it's dropped; one without a date sorts last.
    nonisolated static func snapshots(from payload: [Components.Schemas.DiskSnapshot]) -> [Snapshot] {
        payload
            .compactMap { item in
                item.snapshotKey.map { Snapshot(key: $0, createdAt: item.createdAt, instanceID: item.instanceId) }
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
