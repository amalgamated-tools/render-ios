import Foundation
import Observation
import RenderAPI

/// One entry in a service's event timeline.
///
/// `details` used to be unreadable: the spec types it as an undiscriminated `oneOf` whose empty
/// members matched almost every event, so the generated decoder silently dropped every field. It's
/// now patched to a free-form object (`Scripts/freeform-event-details.py`) and read into
/// ``EventDetails`` — just the deploy, instance and failure-reason fields the app shows. Reading it
/// can't fail the event: details that don't parse become ``EventDetails/empty``.
struct ServiceEvent: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    let type: Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload
    let details: EventDetails

    init(_ event: Components.Schemas.ServiceEventWithCursor.EventPayload) {
        self.id = event.id
        self.timestamp = event.timestamp
        self.type = event._type
        self.details = EventDetails(event.details.additionalProperties)
    }

    /// Building one directly, for tests — where constructing a whole generated payload would say
    /// nothing the fields don't.
    init(
        id: String,
        timestamp: Date,
        type: Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload,
        details: EventDetails = .empty
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.details = details
    }

    /// Why it happened, in Render's terms: the structured failure reason when there is one, else the
    /// `message` that image-pull and artifact-fetch failures send instead. Notifications use this,
    /// so an alert and its timeline row give the same reason.
    var cause: String? {
        details.failure?.summary ?? details.message.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The one-line cause, when the event is a failure that says why.
    ///
    /// A run that failed without a reason still reads as failed, so the timeline can tell "cron run
    /// ended" from "cron run failed" — the type alone is the same for both.
    var reasonSummary: String? {
        if let cause { return cause }
        if details.deployStatus == "failed" || details.buildStatus == "failed" || details.runFailed == true {
            return "Failed"
        }
        return nil
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
