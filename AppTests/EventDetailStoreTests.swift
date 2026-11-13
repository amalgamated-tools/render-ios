import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("EventDetailStore and AccountStore")
struct EventDetailStoreTests {
    /// A real `GET /events/{id}` response, IDs shortened.
    private nonisolated static let failedDeploy = #"""
    {"details":{"deployId":"dep-1","deployStatus":"failed",
     "reason":{"failure":{"evicted":false,"oomKilled":{"memoryLimit":"512Mi"}}},"status":4},
     "id":"evt-1","serviceId":"srv-1","timestamp":"2026-11-07T03:47:37.132243Z","type":"deploy_ended"}
    """#

    @Test("fetches the event by ID and reads its cause")
    func loads() async throws {
        let (client, transport) = RenderClient.routed { _ in (200, Self.failedDeploy) }
        let store = EventDetailStore(client: client, eventID: "evt-1")

        await store.load()

        #expect(transport.requests.first?.path?.hasSuffix("/events/evt-1") == true)
        #expect(store.event?.type == .deployEnded)
        #expect(store.event?.details.deployID == "dep-1")
        #expect(store.event?.reasonSummary == "Out of memory (512Mi limit)")
        #expect(store.rawDetails?.contains("\"memoryLimit\" : \"512Mi\"") == true)
        #expect(store.errorMessage == nil)
    }

    @Test("a failed fetch keeps the timeline's copy on screen")
    func keepsPreviewOnError() async {
        let (client, _) = RenderClient.routed { _ in (404, #"{"message":"not found"}"#) }
        let preview = ServiceEvent(id: "evt-1", timestamp: .now, type: .serverFailed)
        let store = EventDetailStore(client: client, eventID: "evt-1", preview: preview)

        await store.load()

        #expect(store.event == preview)
        #expect(store.errorMessage != nil)
    }

    @Test("an empty details object shows no raw section")
    func emptyRawDetails() async {
        let body = #"{"details":{},"id":"evt-1","serviceId":"srv-1","timestamp":"2026-11-07T03:47:37Z","type":"service_suspended"}"#
        let (client, _) = RenderClient.routed { _ in (200, body) }
        let store = EventDetailStore(client: client, eventID: "evt-1")

        await store.load()

        #expect(store.event?.type == .serviceSuspended)
        #expect(store.rawDetails == nil)
    }

    @Test("the account loads from GET /users")
    func accountLoads() async {
        let (client, transport) = RenderClient.routed { _ in
            (200, #"{"id":"usr-1","name":"Ada Lovelace","email":"ada@example.com"}"#)
        }
        let store = AccountStore(client: client)

        await store.load()

        #expect(transport.requests.first?.path?.hasSuffix("/users") == true)
        #expect(store.user == .init(id: "usr-1", name: "Ada Lovelace", email: "ada@example.com"))
    }

    @Test("a failed account fetch leaves nothing to show, without an error")
    func accountFailure() async {
        let (client, _) = RenderClient.routed { _ in (401, #"{"message":"unauthorized"}"#) }
        let store = AccountStore(client: client)

        await store.load()

        #expect(store.user == nil)
    }

    @Test("a notification's event ID survives the round trip into a navigation target")
    func routerReadsEventID() {
        let target = NotificationRouter.target(
            from: ["serviceID": "srv-1", "ownerID": "tea-1", "eventID": "evt-1"],
            name: "api"
        )
        let older = NotificationRouter.target(from: ["serviceID": "srv-1", "ownerID": "tea-1"], name: "api")

        #expect(target?.eventID == "evt-1")
        // Notifications posted before this change still open the service.
        #expect(older?.eventID == nil)
        #expect(older?.serviceID == "srv-1")
    }
}
