import Foundation
import Observation
import RenderAPI

/// A service's disk and the snapshots Render has taken of it.
///
/// The disk itself comes from the service details the detail screen already loaded, so only the
/// snapshot list is fetched here. Read-only: resizing and restoring come later, behind confirmations.
@MainActor
@Observable
final class DiskStore {
    struct Snapshot: Identifiable, Hashable, Sendable {
        /// Render's opaque restore key. Unique per snapshot, so it doubles as the identity.
        let id: String
        let createdAt: Date?
        /// The instance the snapshot was taken from.
        let instanceID: String?
    }

    private(set) var snapshots: [Snapshot] = []
    private(set) var error: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    private let client: RenderClient
    let diskID: String

    init(client: RenderClient, diskID: String) {
        self.client = client
        self.diskID = diskID
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await client.api
                .listSnapshots(path: .init(diskId: diskID))
                .ok.body.json
            snapshots = Self.snapshots(from: fetched)
            error = nil
            hasLoaded = true
        } catch {
            self.error = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
        }
    }

    /// Newest first, since "how recent is my last snapshot?" is the question. A snapshot without a
    /// key can't be restored or told apart from another, so it's dropped; one without a date sorts last.
    nonisolated static func snapshots(from payload: [Components.Schemas.DiskSnapshot]) -> [Snapshot] {
        payload
            .compactMap { item in
                item.snapshotKey.map { Snapshot(id: $0, createdAt: item.createdAt, instanceID: item.instanceId) }
            }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
    }
}
