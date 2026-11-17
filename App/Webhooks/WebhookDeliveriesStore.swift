import Foundation
import Observation
import RenderAPI

/// One attempt by Render to send an event to a webhook's URL.
struct WebhookDelivery: Identifiable, Hashable, Sendable {
    let id: String
    let eventID: String
    /// As Render sent it; may be a type this build doesn't know.
    let eventType: String
    let sentAt: Date
    /// The URL's HTTP status, or nil when there was no response.
    let statusCode: Int?
    let responseBody: String?
    /// Set when the delivery failed without a response, such as a timeout.
    let error: String?

    var succeeded: Bool { statusCode.map { (200..<300).contains($0) } ?? false }

    /// "200", "405" or "Failed: <error>", for the row's trailing text.
    var outcome: String {
        if let statusCode { return "\(statusCode)" }
        if let error, !error.isEmpty { return "Failed: \(error)" }
        return "No response"
    }
}

/// A webhook's delivery history, newest first, a page at a time.
@MainActor
@Observable
final class WebhookDeliveriesStore {
    private(set) var deliveries: [WebhookDelivery] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var hasMore: Bool { nextCursor != nil }

    private let client: RenderClient
    let webhookID: String
    private let pageSize: Int
    private var nextCursor: String?
    /// Bumped by each fresh load, so a page requested before it can't land on the new list.
    private var generation = 0

    init(client: RenderClient, webhookID: String, pageSize: Int = 20) {
        self.client = client
        self.webhookID = webhookID
        self.pageSize = pageSize
    }

    func load() async {
        generation += 1
        await loadPage(after: nil, generation: generation, replacing: true)
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        await loadPage(after: cursor, generation: generation, replacing: false)
    }

    private func loadPage(after cursor: String?, generation current: Int, replacing: Bool) async {
        let client = client
        let webhookID = webhookID
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let paginator = CursorPaginator(pageSize: pageSize) { cursor, limit in
                try await client.api
                    .listWebhookEvents(path: .init(webhookId: webhookID), query: .init(limit: limit, cursor: cursor))
                    .ok.body.json
            } unwrap: { envelope in
                let event = envelope.webhookEvent
                return (
                    WebhookDelivery(
                        id: event.id, eventID: event.eventId, eventType: event.eventType, sentAt: event.sentAt,
                        statusCode: event.statusCode, responseBody: event.responseBody, error: event.error
                    ),
                    envelope.cursor
                )
            }
            let page = try await paginator.firstPage(after: cursor)
            guard current == generation else { return }
            let known = replacing ? [] : deliveries
            deliveries = known + page.elements.filter { delivery in !known.contains { $0.id == delivery.id } }
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = RenderError.wrapping(error).errorDescription
        }
        hasLoaded = true
    }
}
