import Foundation

/// How far one service's timeline has already been examined.
///
/// A timestamp alone is not enough. `startTime` on `GET /services/{id}/events` is **inclusive**, and
/// Render routinely emits several events inside the same second — `deploy_ended`, `server_available`
/// and `build_ended` land together at the end of a deploy. A timestamp-only watermark therefore has
/// to choose between re-alerting on the boundary event every poll (advance to `lastSeen`) and
/// stepping straight over its siblings (advance to `lastSeen + 1s`). Neither is acceptable for an
/// alert.
///
/// So both are kept: the newest timestamp seen, and the IDs of the most recent events. The request
/// re-fetches the boundary; the ID set removes what was already reported.
struct EventWatermark: Codable, Hashable, Sendable {
    var lastSeen: Date
    /// Newest first, capped at ``EventWatermark/recentIDLimit``. Only has to outlive the overlap the
    /// inclusive `startTime` creates, which is one timestamp's worth of events.
    var recentIDs: [String]

    static let recentIDLimit = 50

    init(lastSeen: Date, recentIDs: [String] = []) {
        self.lastSeen = lastSeen
        self.recentIDs = recentIDs
    }

    /// Records a batch of examined events, newest first.
    mutating func advance(over events: [ServiceEvent]) {
        guard !events.isEmpty else { return }
        lastSeen = max(lastSeen, events.map(\.timestamp).max() ?? lastSeen)
        recentIDs = Array((events.map(\.id) + recentIDs).prefix(Self.recentIDLimit))
    }

    func hasSeen(_ eventID: String) -> Bool {
        recentIDs.contains(eventID)
    }
}

/// Per-service watermarks, persisted so a poll after a relaunch doesn't replay history.
///
/// Deliberately separate from ``WatchlistStore``: the two have different lifetimes. Un-watching and
/// re-watching a service should start from *now*, which falls out of removing the watermark with the
/// watchlist entry — but a watchlist that survives a relaunch and a watermark that doesn't would
/// re-announce every failure of the last hour on first launch.
@MainActor
final class EventWatermarkStore {
    private var watermarks: [String: EventWatermark]
    private let defaults: UserDefaults
    private static let key = "eventWatermarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        watermarks = Self.read(from: defaults)
    }

    subscript(serviceID: String) -> EventWatermark? {
        get { watermarks[serviceID] }
        set {
            watermarks[serviceID] = newValue
            persist()
        }
    }

    /// Marks a service as examined up to `date` with nothing to report — how watching starts, so
    /// turning it on never announces something that already happened.
    func begin(serviceID: String, at date: Date) {
        guard watermarks[serviceID] == nil else { return }
        self[serviceID] = EventWatermark(lastSeen: date)
    }

    func forget(serviceID: String) {
        watermarks.removeValue(forKey: serviceID)
        persist()
    }

    /// Drops watermarks for services no longer watched, so an un-watched service doesn't leave a
    /// stale entry that quietly suppresses alerts if it's ever watched again.
    func prune(keeping serviceIDs: Set<String>) {
        let stale = watermarks.keys.filter { !serviceIDs.contains($0) }
        guard !stale.isEmpty else { return }
        stale.forEach { watermarks.removeValue(forKey: $0) }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(watermarks) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func read(from defaults: UserDefaults) -> [String: EventWatermark] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: EventWatermark].self, from: data)
        else { return [:] }
        return decoded
    }
}
