import Foundation
import Observation
import RenderAPI

/// A webhook as the app shows it. The spec inlines the same object in four operations, so this
/// flattens them into one value.
struct Webhook: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: String
    /// Signs every delivery. A secret: shown only on request.
    let secret: String
    let isEnabled: Bool
    /// Event types that trigger it, as Render sends them. Empty means every event type.
    let eventFilter: [String]

    var receivesAllEvents: Bool { eventFilter.isEmpty }

    init(id: String, name: String, url: String, secret: String, isEnabled: Bool, eventFilter: [String]?) {
        self.id = id
        self.name = name
        self.url = url
        self.secret = secret
        self.isEnabled = isEnabled
        self.eventFilter = eventFilter ?? []
    }
}

extension Webhook {
    init(_ payload: Components.Schemas.WebhookWithCursor.WebhookPayload) {
        self.init(id: payload.id, name: payload.name, url: payload.url, secret: payload.secret,
                  isEnabled: payload.enabled, eventFilter: payload.eventFilter)
    }

    init(_ payload: Operations.CreateWebhook.Output.Created.Body.JsonPayload) {
        self.init(id: payload.id, name: payload.name, url: payload.url, secret: payload.secret,
                  isEnabled: payload.enabled, eventFilter: payload.eventFilter)
    }

    init(_ payload: Operations.RetrieveWebhook.Output.Ok.Body.JsonPayload) {
        self.init(id: payload.id, name: payload.name, url: payload.url, secret: payload.secret,
                  isEnabled: payload.enabled, eventFilter: payload.eventFilter)
    }

    init(_ payload: Operations.UpdateWebhook.Output.Ok.Body.JsonPayload) {
        self.init(id: payload.id, name: payload.name, url: payload.url, secret: payload.secret,
                  isEnabled: payload.enabled, eventFilter: payload.eventFilter)
    }
}

/// Webhook event types: the list the app offers, and readable names for any type, including ones
/// Render adds after this build.
enum WebhookEventType {
    /// Every type the spec lets a request send, in Render's order.
    static var all: [String] {
        Operations.CreateWebhook.Input.Body.JsonPayload.EventFilterPayloadPayload.allCases.map(\.rawValue)
    }

    /// `deploy_ended` → "Deploy ended", `postgres_ha_status_changed` → "Postgres HA status changed".
    static func displayName(_ raw: String) -> String {
        let acronyms: Set<String> = ["ha", "pitr", "wal", "uri"]
        let words = raw.split(separator: "_").enumerated().map { index, word -> String in
            let word = String(word)
            if acronyms.contains(word) { return word.uppercased() }
            return index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
        }
        return words.joined(separator: " ")
    }

    /// A heading for the picker, from the type's first word.
    static func group(_ raw: String) -> String {
        switch raw.split(separator: "_").first.map(String.init) ?? "" {
        case "build", "deploy", "pre", "commit", "branch", "auto", "artifact", "image", "pipeline", "zero":
            "Builds and Deploys"
        case "server", "instance", "service", "plan", "maintenance", "autoscaling", "edge":
            "Services"
        case "cron", "job":
            "Cron Jobs and Jobs"
        case "postgres":
            "Postgres"
        case "key":
            "Key Value"
        case "disk":
            "Disks"
        default:
            "Other"
        }
    }
}

/// What the create and edit sheet submits.
struct WebhookDraft: Hashable, Sendable {
    var name: String
    var url: String
    var isEnabled: Bool
    /// Empty means every event type.
    var eventFilter: Set<String>

    init(name: String = "", url: String = "https://", isEnabled: Bool = true, eventFilter: Set<String> = []) {
        self.name = name
        self.url = url
        self.isEnabled = isEnabled
        self.eventFilter = eventFilter
    }

    init(_ webhook: Webhook) {
        self.init(name: webhook.name, url: webhook.url, isEnabled: webhook.isEnabled, eventFilter: Set(webhook.eventFilter))
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the draft can't be saved, or nil when it can. Render itself checks only that the URL uses
    /// https ("webhook URL must use https") and accepts an empty name.
    func validationMessage(editing original: Webhook?) -> String? {
        if trimmedName.isEmpty { return "Enter a name." }
        guard let parsed = URL(string: trimmedURL), parsed.scheme?.lowercased() == "https",
              let host = parsed.host(), !host.isEmpty
        else { return "Enter an https:// URL." }
        // Render ignores an empty filter on an update, so a webhook with a filter can't be switched
        // back to every event from here.
        if let original, !original.receivesAllEvents, eventFilter.isEmpty {
            return "Render can't remove a filter from an existing webhook. Choose at least one event."
        }
        // A type the spec doesn't list can't be sent back, and dropping it quietly would change the
        // webhook. Only matters when the filter is being changed.
        if eventFilter != Set(original?.eventFilter ?? []) {
            let unknown = eventFilter.subtracting(WebhookEventType.all).sorted()
            if !unknown.isEmpty {
                return "This webhook filters on event types this app doesn't know (\(unknown.joined(separator: ", "))). Change its events in the Render Dashboard."
            }
        }
        return nil
    }
}

/// The workspace's webhooks: list, create, update and delete.
///
/// What the live API showed, which shaped this:
/// - A webhook with no filter comes back as `eventFilter: null`, and event types are an open set,
///   so responses are made lenient by `Scripts/webhook-quirks.py`.
/// - An update with `eventFilter: []` or `null` leaves an existing filter in place, so the edit
///   sheet won't offer "every event" for a webhook that has a filter.
/// - Render stores any string as a filter, so only the spec's event types are offered.
/// - The URL must use https. The name may be empty, but the sheet asks for one.
@MainActor
@Observable
final class WebhooksStore {
    /// Sorted by name.
    private(set) var webhooks: [Webhook] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private let client: RenderClient
    let ownerID: String
    /// Bumped by every load and by every write, when it starts and when it ends, so a refresh that
    /// overlaps a write can't put back what the write changed.
    private var generation = 0

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
    }

    func webhook(id: String) -> Webhook? { webhooks.first { $0.id == id } }

    func load() async {
        generation += 1
        let current = generation
        let client = client
        let ownerID = ownerID
        do {
            let paginator = CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listWebhooks(query: .init(cursor: cursor, limit: limit, ownerId: [ownerID]))
                    .ok.body.json
            } unwrap: { envelope in
                (Webhook(envelope.webhook), envelope.cursor)
            }
            let listed = try await paginator.collect(limit: 500)
            guard current == generation else { return }
            webhooks = Self.sorted(listed)
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = Self.message(for: error)
        }
        hasLoaded = true
    }

    /// Creates a webhook. Returns it when Render accepted it.
    @discardableResult
    func create(_ draft: WebhookDraft) async -> Webhook? {
        guard !isSaving, draft.validationMessage(editing: nil) == nil else { return nil }
        guard let filter = Self.requestFilter(draft.eventFilter, as: Operations.CreateWebhook.Input.Body.JsonPayload.EventFilterPayloadPayload.self) else { return nil }
        beginWrite()
        defer { endWrite() }
        do {
            let created = try await client.api.createWebhook(body: .json(.init(
                ownerId: ownerID,
                url: draft.trimmedURL,
                name: draft.trimmedName,
                enabled: draft.isEnabled,
                eventFilter: filter
            ))).created.body.json
            let webhook = Webhook(created)
            webhooks = Self.sorted(webhooks.filter { $0.id != webhook.id } + [webhook])
            actionResult = ActionResult(message: "Created \(webhook.name).", isFailure: false)
            return webhook
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return nil
        }
    }

    /// Sends only the fields that differ from `original`. Returns whether Render accepted it.
    @discardableResult
    func update(_ original: Webhook, to draft: WebhookDraft) async -> Bool {
        guard !isSaving, draft.validationMessage(editing: original) == nil else { return false }
        let name = draft.trimmedName == original.name ? nil : draft.trimmedName
        let url = draft.trimmedURL == original.url ? nil : draft.trimmedURL
        let enabled = draft.isEnabled == original.isEnabled ? nil : draft.isEnabled
        var filter: [Operations.UpdateWebhook.Input.Body.JsonPayload.EventFilterPayloadPayload]?
        if draft.eventFilter != Set(original.eventFilter) {
            guard let mapped = Self.requestFilter(draft.eventFilter, as: Operations.UpdateWebhook.Input.Body.JsonPayload.EventFilterPayloadPayload.self) else { return false }
            filter = mapped
        }
        guard name != nil || url != nil || enabled != nil || filter != nil else { return true }

        beginWrite()
        defer { endWrite() }
        do {
            let updated = try await client.api.updateWebhook(
                path: .init(webhookId: original.id),
                body: .json(.init(name: name, url: url, enabled: enabled, eventFilter: filter))
            ).ok.body.json
            replace(Webhook(updated))
            if enabled != nil, name == nil, url == nil, filter == nil {
                actionResult = ActionResult(message: draft.isEnabled ? "Webhook on." : "Webhook off.", isFailure: false)
            } else {
                actionResult = ActionResult(message: "Saved \(updated.name).", isFailure: false)
            }
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    /// Returns whether Render deleted it.
    @discardableResult
    func delete(_ webhook: Webhook) async -> Bool {
        guard !isSaving else { return false }
        beginWrite()
        defer { endWrite() }
        do {
            _ = try await client.api.deleteWebhook(path: .init(webhookId: webhook.id)).noContent
            webhooks.removeAll { $0.id == webhook.id }
            actionResult = ActionResult(message: "Deleted \(webhook.name).", isFailure: false)
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    // MARK: - Internals

    private func beginWrite() {
        isSaving = true
        actionResult = nil
        generation += 1
    }

    private func endWrite() {
        generation += 1
        isSaving = false
    }

    private func replace(_ webhook: Webhook) {
        webhooks = Self.sorted(webhooks.filter { $0.id != webhook.id } + [webhook])
    }

    /// The draft's filter as the generated request enum, in Render's order. Nil if it holds a type
    /// the spec doesn't list, which the sheet can't produce, but which a webhook made elsewhere may
    /// already have.
    private static func requestFilter<T: RawRepresentable & CaseIterable>(_ filter: Set<String>, as _: T.Type) -> [T]? where T.RawValue == String {
        let mapped = T.allCases.filter { filter.contains($0.rawValue) }
        return mapped.count == filter.count ? Array(mapped) : nil
    }

    private static func sorted(_ webhooks: [Webhook]) -> [Webhook] {
        webhooks.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
