import Foundation
import Observation
import RenderAPI

/// One event, fetched by ID from `GET /events/{eventId}` — which is how a tapped failure
/// notification gets from "something broke" to *what* broke.
///
/// Opened from the timeline it starts with that row's copy (``init(client:eventID:preview:)``), so the
/// screen is never blank while the fetch runs; the fetch then adds the raw details the row didn't
/// keep. Opened from a notification there is no row, and the fetch is the whole screen.
@MainActor
@Observable
final class EventDetailStore {
    private(set) var event: ServiceEvent?
    /// The full `details` object, pretty-printed — for event types the app has no fields for.
    private(set) var rawDetails: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let client: RenderClient
    let eventID: String

    init(client: RenderClient, eventID: String, preview: ServiceEvent? = nil) {
        self.client = client
        self.eventID = eventID
        self.event = preview
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let payload = try await client.api
                .retrieveEvent(path: .init(eventId: eventID))
                .ok.body.json
            // The single-event response has its own copy of the type enum. Same raw values — both are
            // generated from the same list — but going through the raw value means a type one side
            // knows and the other doesn't is an error here rather than a miscompile later.
            guard let type = Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload(
                rawValue: payload._type.rawValue
            ) else {
                errorMessage = "Render sent an event type this version of the app doesn't know."
                return
            }
            let container = payload.details.additionalProperties
            event = ServiceEvent(
                id: payload.id,
                timestamp: payload.timestamp,
                type: type,
                details: EventDetails(container)
            )
            rawDetails = Self.prettyJSON(container)
            errorMessage = nil
        } catch {
            // A row already on screen stays there; the error says why it couldn't be refreshed.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// `nil` for an empty object — "{}" on screen says nothing useful.
    static func prettyJSON(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8),
              text != "{\n\n}", text != "{}"
        else { return nil }
        return text
    }
}
