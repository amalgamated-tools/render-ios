import Foundation
import Testing

@testable import RenderiOS

@MainActor
@Suite("WatchlistStore")
struct WatchlistStoreTests {
    @Test("watching survives a relaunch")
    func persists() throws {
        let defaults = makeTestDefaults()
        let store = WatchlistStore(defaults: defaults)
        store.add(id: "srv-1", ownerID: "tea-1", name: "api")

        let reopened = WatchlistStore(defaults: defaults)

        #expect(reopened.isWatching("srv-1"))
        #expect(reopened.watched.first?.ownerID == "tea-1")
        #expect(reopened.watched.first?.name == "api")
    }

    @Test("adding a service already watched refreshes its name rather than duplicating it")
    func addIsIdempotent() throws {
        let store = WatchlistStore(defaults: makeTestDefaults())
        store.add(id: "srv-1", ownerID: "tea-1", name: "api")

        #expect(store.add(id: "srv-1", ownerID: "tea-1", name: "api-gateway"))

        #expect(store.watched.count == 1)
        // A rename shouldn't have to wait for the next failure to show up correctly.
        #expect(store.watched.first?.name == "api-gateway")
    }

    @Test("the cap is reported rather than enforced silently")
    func capIsReported() throws {
        let store = WatchlistStore(defaults: makeTestDefaults())
        for index in 0..<WatchlistStore.limit {
            #expect(store.add(id: "srv-\(index)", ownerID: "tea-1", name: "svc-\(index)"))
        }

        #expect(store.isFull)
        // False, not a silent no-op: a toggle that snaps back with no explanation reads as a bug.
        #expect(store.add(id: "srv-extra", ownerID: "tea-1", name: "extra") == false)
        #expect(store.watched.count == WatchlistStore.limit)
    }

    @Test("a full list still accepts a rename of something already on it")
    func fullListStillRenames() throws {
        let store = WatchlistStore(defaults: makeTestDefaults())
        for index in 0..<WatchlistStore.limit {
            store.add(id: "srv-\(index)", ownerID: "tea-1", name: "svc-\(index)")
        }

        #expect(store.add(id: "srv-0", ownerID: "tea-1", name: "renamed"))
        #expect(store.watched.first { $0.id == "srv-0" }?.name == "renamed")
    }

    @Test("the settings screen sees one workspace's services, sorted")
    func slicesByOwner() throws {
        let store = WatchlistStore(defaults: makeTestDefaults())
        store.add(id: "srv-1", ownerID: "tea-1", name: "worker")
        store.add(id: "srv-2", ownerID: "tea-2", name: "other")
        store.add(id: "srv-3", ownerID: "tea-1", name: "api")

        #expect(store.watched(ownedBy: "tea-1").map(\.name) == ["api", "worker"])
    }

    @Test("signing out clears the list, and the clearing persists")
    func removeAllPersists() throws {
        let defaults = makeTestDefaults()
        let store = WatchlistStore(defaults: defaults)
        store.add(id: "srv-1", ownerID: "tea-1", name: "api")

        store.removeAll()

        #expect(store.watched.isEmpty)
        #expect(WatchlistStore(defaults: defaults).watched.isEmpty)
    }
}

@MainActor
@Suite("EventWatermarkStore")
struct EventWatermarkStoreTests {
    private let start = Date(timeIntervalSince1970: 1_770_000_000)

    @Test("advancing takes the newest timestamp and remembers the IDs")
    func advance() throws {
        var watermark = EventWatermark(lastSeen: start)
        watermark.advance(over: [
            event(id: "evt-2", at: start.addingTimeInterval(60)),
            event(id: "evt-1", at: start),
        ])

        #expect(watermark.lastSeen == start.addingTimeInterval(60))
        #expect(watermark.hasSeen("evt-1"))
        #expect(watermark.hasSeen("evt-2"))
        #expect(!watermark.hasSeen("evt-3"))
    }

    @Test("an empty batch leaves the watermark exactly where it was")
    func advanceOverNothing() throws {
        var watermark = EventWatermark(lastSeen: start, recentIDs: ["evt-1"])
        watermark.advance(over: [])

        #expect(watermark.lastSeen == start)
        #expect(watermark.recentIDs == ["evt-1"])
    }

    @Test("an out-of-order batch can't move the watermark backwards")
    func advanceNeverGoesBackwards() throws {
        var watermark = EventWatermark(lastSeen: start.addingTimeInterval(600))
        watermark.advance(over: [event(id: "evt-1", at: start)])

        #expect(watermark.lastSeen == start.addingTimeInterval(600))
    }

    @Test("the ID list stays bounded, keeping the newest")
    func recentIDsAreBounded() throws {
        var watermark = EventWatermark(lastSeen: start)
        // Two full batches, so the older one is the part that has to fall off.
        for batch in 0..<2 {
            watermark.advance(over: (0..<EventWatermark.recentIDLimit).map {
                event(id: "batch\(batch)-evt-\($0)", at: start.addingTimeInterval(Double(batch)))
            })
        }

        #expect(watermark.recentIDs.count == EventWatermark.recentIDLimit)
        #expect(watermark.hasSeen("batch1-evt-0"))
        #expect(!watermark.hasSeen("batch0-evt-0"))
    }

    @Test("re-examining the same boundary event doesn't spend the ID budget on copies of it")
    func recentIDsAreDeduplicated() throws {
        // What an idle service actually produces: `startTime` is inclusive, so the newest event
        // comes back on every single poll. Prepending it each time fills all 50 slots with one ID
        // inside a day, and then a service that finally emits a batch has nothing left to be
        // recognised against.
        var watermark = EventWatermark(lastSeen: start)
        let boundary = event(id: "evt-boundary", at: start.addingTimeInterval(60))
        for _ in 0..<(EventWatermark.recentIDLimit * 2) {
            watermark.advance(over: [boundary])
        }

        #expect(watermark.recentIDs == ["evt-boundary"])

        // And the budget is still there for the events that need it.
        watermark.advance(over: (0..<10).map {
            event(id: "evt-\($0)", at: start.addingTimeInterval(120))
        })
        #expect(watermark.hasSeen("evt-boundary"))
        #expect(watermark.hasSeen("evt-0"))
        #expect(watermark.recentIDs.count == 11)
    }

    @Test("watermarks survive a relaunch, so a restart doesn't replay history")
    func persists() throws {
        let defaults = makeTestDefaults()
        let store = EventWatermarkStore(defaults: defaults)
        store["srv-1"] = EventWatermark(lastSeen: start, recentIDs: ["evt-1"])

        let reopened = EventWatermarkStore(defaults: defaults)

        #expect(reopened["srv-1"]?.lastSeen == start)
        #expect(reopened["srv-1"]?.hasSeen("evt-1") == true)
    }

    @Test("begin only stamps a service that has never been examined")
    func beginDoesNotResetProgress() throws {
        let store = EventWatermarkStore(defaults: makeTestDefaults())
        store.begin(serviceID: "srv-1", at: start)
        store.begin(serviceID: "srv-1", at: start.addingTimeInterval(3600))

        // Otherwise every launch would skip whatever happened while the app was closed.
        #expect(store["srv-1"]?.lastSeen == start)
    }

    private func event(id: String, at timestamp: Date) -> ServiceEvent {
        ServiceEvent(id: id, timestamp: timestamp, type: .serverFailed)
    }
}
