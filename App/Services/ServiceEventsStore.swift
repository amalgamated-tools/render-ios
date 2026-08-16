import Foundation
import Observation
import RenderAPI

/// One entry in a service's event timeline.
///
/// **Only `type` and `timestamp` are carried, deliberately.** `serviceEvent.details` is an
/// undiscriminated 44-member `oneOf`, and its second member has *no* required properties — so the
/// generated first-match decoder matches that empty member for essentially every event whose details
/// aren't the first shape, and reports it as a successful decode. Reading a deploy ID or a failure
/// reason out of it would be reading a value the decoder never actually looked for.
///
/// The upside: that same empty member means the union can never *fail*, so events always load.
/// Making details usable needs a spec patch replacing the `oneOf` with a free-form object (the
/// generator then emits a dictionary) — worth doing, but it belongs with the feature that needs it.
struct ServiceEvent: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let type: Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload

    init(_ event: Components.Schemas.ServiceEventWithCursor.EventPayload) {
        self.id = event.id
        self.timestamp = event.timestamp
        self.type = event._type
    }

    /// Building one directly, for tests over the watermark rules — where constructing a whole
    /// generated payload would say nothing the three fields don't.
    init(id: String, timestamp: Date, type: Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
    }
}

/// Loads a service's event timeline, newest first, paging **by time window rather than by cursor**.
///
/// `GET /services/{id}/events` accepts a `cursor` like every other list endpoint, but the response
/// envelope can't return one: `serviceEventWithCursor` lists `cursor` in its `required` array and then
/// never defines the property, so the generator drops it entirely (one of the spec typos Phase 0
/// catalogued). `CursorPaginator` is therefore unusable here.
///
/// Instead each page asks for events strictly older than the oldest one already held, via `endTime`.
/// Events with identical timestamps are the failure mode that would loop, so pages are de-duplicated
/// by ID and a page that yields nothing new ends the timeline.
@MainActor
@Observable
final class ServiceEventsStore {
    private(set) var events: [ServiceEvent] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = true

    private let client: RenderClient
    private let serviceID: String
    private let pageSize: Int
    private var seenIDs: Set<String> = []

    /// - Parameter pageSize: The endpoint caps `limit` at 100.
    init(client: RenderClient, serviceID: String, pageSize: Int = 30) {
        self.client = client
        self.serviceID = serviceID
        self.pageSize = pageSize
    }

    func refresh() async {
        events = []
        seenIDs = []
        hasMore = true
        errorMessage = nil
        await loadNextPage()
    }

    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.api
                .listEvents(
                    path: .init(serviceId: serviceID),
                    // `endTime` is inclusive, so re-requesting the oldest timestamp can return events
                    // already held; the ID filter below removes them.
                    query: .init(endTime: events.last?.timestamp, limit: pageSize)
                )
                .ok.body.json
                .map { ServiceEvent($0.event) }

            let fresh = page.filter { seenIDs.insert($0.id).inserted }
            events.append(contentsOf: fresh)
            // Two independent stops: a short page means the service has no older events, and an
            // all-duplicates page means the window can't advance (every event shares a timestamp).
            hasMore = page.count >= pageSize && !fresh.isEmpty
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            hasMore = false
        }
    }
}
