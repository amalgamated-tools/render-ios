import Foundation
import Observation

/// A service the user has asked to be told about.
///
/// The owner ID and the name travel with the service ID deliberately. The poll runs with no screen
/// on-screen and no workspace "selected", so it has to know which owner each service belongs to; and
/// carrying the name means a notification can say `api` rather than `srv-cph1rs3i…` without spending
/// a `retrieveService` call inside a background budget measured in seconds.
struct WatchedService: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let ownerID: String
    var name: String
}

/// The services this device watches for failures, across every workspace.
///
/// One flat list rather than a per-owner key, because the reader that matters is the background
/// poll: it wakes up with no active workspace and needs the whole set in one read. The UI slices it
/// by owner; the poll doesn't.
///
/// Not secret, so `UserDefaults` — same reasoning as `selectedOwnerID` and `selectedProjectID`.
@MainActor
@Observable
final class WatchlistStore {
    /// Every watched service costs one request per background wake, inside a budget iOS measures in
    /// seconds and against an API that rate-limits. A cap the user can see beats a list that
    /// silently stops being checked in time.
    static let limit = 20

    private(set) var watched: [WatchedService] = []

    private let defaults: UserDefaults
    private static let key = "watchedServices"

    /// - Parameter defaults: Injection seam for tests, so a run doesn't leave a watchlist behind in
    ///   the app's own defaults.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watched = Self.read(from: defaults)
    }

    var isFull: Bool { watched.count >= Self.limit }

    func isWatching(_ serviceID: String) -> Bool {
        watched.contains { $0.id == serviceID }
    }

    func watched(ownedBy ownerID: String) -> [WatchedService] {
        watched
            .filter { $0.ownerID == ownerID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Starts watching, or refreshes the stored name of a service already watched (a rename should
    /// not have to wait for the next failure to show up correctly).
    ///
    /// - Returns: `false` when the list is full and this is a new service, so the caller can say so
    ///   rather than leave a toggle that silently snaps back.
    @discardableResult
    func add(id: String, ownerID: String, name: String) -> Bool {
        if let index = watched.firstIndex(where: { $0.id == id }) {
            watched[index].name = name
            persist()
            return true
        }
        guard !isFull else { return false }
        watched.append(WatchedService(id: id, ownerID: ownerID, name: name))
        persist()
        return true
    }

    func remove(id: String) {
        watched.removeAll { $0.id == id }
        persist()
    }

    /// Clears the whole list. Used on sign-out: a watchlist that outlived the credential would poll
    /// with someone else's session, or with none.
    func removeAll() {
        watched = []
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(watched) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func read(from defaults: UserDefaults) -> [WatchedService] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([WatchedService].self, from: data)
        else { return [] }
        return decoded
    }
}
