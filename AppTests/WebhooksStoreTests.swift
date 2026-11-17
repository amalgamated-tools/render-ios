import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Webhooks: decoding what Render sends, the draft's rules, the writes, and delivery history.
@MainActor
@Suite("Webhooks")
struct WebhooksStoreTests {
    /// Render's answers, changeable mid-test, plus the bodies the store sent.
    private final class Backend: @unchecked Sendable {
        private let lock = NSLock()
        private var _list: (Int, String) = (200, "[]")
        private var _write: (Int, String)?
        private var _deliveries: (Int, String) = (200, "[]")
        private var _nextDeliveries: (cursor: String, answer: (Int, String))?
        private var _bodies: [(method: HTTPRequest.Method, body: [String: Any])] = []
        private var _listGate: Gate?

        var list: (Int, String) { get { lock.withLock { _list } } set { lock.withLock { _list = newValue } } }
        /// When nil, a create or update answers with `WebhooksStoreTests.webhookJSON` built from its body.
        var write: (Int, String)? { get { lock.withLock { _write } } set { lock.withLock { _write = newValue } } }
        var deliveries: (Int, String) { get { lock.withLock { _deliveries } } set { lock.withLock { _deliveries = newValue } } }
        var nextDeliveries: (cursor: String, answer: (Int, String))? {
            get { lock.withLock { _nextDeliveries } }
            set { lock.withLock { _nextDeliveries = newValue } }
        }
        var bodies: [(method: HTTPRequest.Method, body: [String: Any])] {
            get { lock.withLock { _bodies } }
            set { lock.withLock { _bodies = newValue } }
        }
        func holdNextList(at gate: Gate) { lock.withLock { _listGate = gate } }
        func takeListGate() -> Gate? { lock.withLock { defer { _listGate = nil }; return _listGate } }
    }

    /// Lets a test hold a request in flight and know when it got there.
    private actor Gate {
        private var entered = false
        private var isOpen = false
        private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiter: CheckedContinuation<Void, Never>?

        func hold() async {
            entered = true
            enteredWaiters.forEach { $0.resume() }
            enteredWaiters = []
            guard !isOpen else { return }
            await withCheckedContinuation { openWaiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { enteredWaiters.append($0) }
        }

        func open() {
            isOpen = true
            openWaiter?.resume()
            openWaiter = nil
        }
    }

    private nonisolated static func webhookJSON(
        id: String = "whk-1", name: String = "deploys", url: String = "https://hooks.example.com/render",
        enabled: Bool = true, filter: String = "null"
    ) -> String {
        #"{"id":"\#(id)","name":"\#(name)","url":"\#(url)","secret":"whsec_test","enabled":\#(enabled),"eventFilter":\#(filter)}"#
    }

    private nonisolated static func listJSON(_ webhooks: [String]) -> String {
        "[" + webhooks.enumerated().map { #"{"cursor":"c\#($0)","webhook":\#($1)}"# }.joined(separator: ",") + "]"
    }

    private nonisolated static func deliveryJSON(_ id: String, type: String, status: Int?, error: String? = nil) -> String {
        var fields = [#""id":"\#(id)""#, #""eventId":"evt-\#(id)""#, #""eventType":"\#(type)""#, #""sentAt":"2026-11-17T02:05:13.443349Z""#]
        if let status { fields.append(#""statusCode":\#(status)"#) }
        if let error { fields.append(#""error":"\#(error)""#) }
        return #"{"cursor":"c-\#(id)","webhookEvent":{\#(fields.joined(separator: ","))}}"#
    }

    private func store(_ backend: Backend) -> (WebhooksStore, StubTransport, RenderClient) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            var answer: (Int, String)
            if request.method == .post || request.method == .patch {
                var data = Data()
                if let body { data = try await Data(collecting: body, upTo: 8192) }
                let sent = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                backend.bodies.append((request.method, sent))
                if let fixed = backend.write {
                    answer = fixed
                } else {
                    let filter = (sent["eventFilter"] as? [String]).map { $0.isEmpty ? "null" : #"[\#($0.map { #""\#($0)""# }.joined(separator: ","))]"# } ?? "null"
                    answer = (request.method == .post ? 201 : 200, Self.webhookJSON(
                        name: sent["name"] as? String ?? "deploys",
                        url: sent["url"] as? String ?? "https://hooks.example.com/render",
                        enabled: sent["enabled"] as? Bool ?? true,
                        filter: filter
                    ))
                }
            } else if request.method == .delete {
                answer = (204, "")
            } else if path.contains("/events") {
                if let next = backend.nextDeliveries, path.contains("cursor=\(next.cursor)") {
                    answer = next.answer
                } else {
                    answer = backend.deliveries
                }
            } else {
                answer = backend.list
                if let gate = backend.takeListGate() { await gate.hold() }
            }
            var response = HTTPResponse(status: .init(code: answer.0))
            response.headerFields = [.contentType: "application/json"]
            return (response, answer.1.isEmpty ? nil : HTTPBody(answer.1))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        return (WebhooksStore(client: client, ownerID: "tea-1"), transport, client)
    }

    // MARK: - Event types

    @Test("event types read as words, with the acronyms kept")
    func eventTypeNames() {
        #expect(WebhookEventType.displayName("deploy_ended") == "Deploy ended")
        #expect(WebhookEventType.displayName("postgres_ha_status_changed") == "Postgres HA status changed")
        #expect(WebhookEventType.displayName("postgres_pitr_checkpoint_failed") == "Postgres PITR checkpoint failed")
        #expect(WebhookEventType.displayName("something_brand_new") == "Something brand new")
        #expect(WebhookEventType.group("deploy_ended") == "Builds and Deploys")
        #expect(WebhookEventType.group("postgres_restarted") == "Postgres")
        #expect(WebhookEventType.group("something_brand_new") == "Other")
        #expect(WebhookEventType.all.contains("server_failed"))
    }

    // MARK: - Draft rules

    @Test("a draft needs a name and an https URL")
    func draftRules() {
        #expect(WebhookDraft(name: "deploys", url: "https://hooks.example.com/x").validationMessage(editing: nil) == nil)
        #expect(WebhookDraft(name: " ", url: "https://hooks.example.com/x").validationMessage(editing: nil) != nil)
        // Render's live answer to both: "webhook URL must use https".
        #expect(WebhookDraft(name: "deploys", url: "http://hooks.example.com/x").validationMessage(editing: nil) != nil)
        #expect(WebhookDraft(name: "deploys", url: "not a url").validationMessage(editing: nil) != nil)
        #expect(WebhookDraft(name: "deploys", url: "https://").validationMessage(editing: nil) != nil)
    }

    @Test("a webhook with a filter can't be switched back to every event")
    func filterCantBeCleared() {
        let filtered = Webhook(id: "whk-1", name: "deploys", url: "https://hooks.example.com/x", secret: "s", isEnabled: true, eventFilter: ["deploy_ended"])
        var draft = WebhookDraft(filtered)
        draft.eventFilter = []
        #expect(draft.validationMessage(editing: filtered)?.contains("can't remove a filter") == true)

        let unfiltered = Webhook(id: "whk-2", name: "all", url: "https://hooks.example.com/x", secret: "s", isEnabled: true, eventFilter: nil)
        var narrowed = WebhookDraft(unfiltered)
        narrowed.eventFilter = ["deploy_ended"]
        #expect(narrowed.validationMessage(editing: unfiltered) == nil)
    }

    @Test("an unknown type in a filter blocks changing the filter, but not other edits")
    func unknownFilterType() {
        // Render stored "bogus_type" when sent it, live.
        let odd = Webhook(id: "whk-1", name: "odd", url: "https://hooks.example.com/x", secret: "s", isEnabled: true, eventFilter: ["bogus_type"])
        var renamed = WebhookDraft(odd)
        renamed.name = "renamed"
        #expect(renamed.validationMessage(editing: odd) == nil)

        var refiltered = WebhookDraft(odd)
        refiltered.eventFilter.insert("deploy_ended")
        #expect(refiltered.validationMessage(editing: odd)?.contains("bogus_type") == true)
    }

    // MARK: - Loading

    @Test("the list decodes a null filter and an unknown event type, sorted by name")
    func loadDecodesLiveShapes() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([
            Self.webhookJSON(id: "whk-b", name: "zeta", filter: "null"),
            Self.webhookJSON(id: "whk-a", name: "alpha", enabled: false, filter: #"["deploy_ended","bogus_type"]"#),
        ]))
        let (store, transport, _) = store(backend)

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.webhooks.map(\.id) == ["whk-a", "whk-b"])
        #expect(store.webhooks[0].eventFilter == ["deploy_ended", "bogus_type"])
        #expect(!store.webhooks[0].isEnabled)
        #expect(store.webhooks[1].receivesAllEvents)
        #expect(transport.requests.first?.path?.contains("ownerId=tea-1") == true)
    }

    // MARK: - Writes

    @Test("creating sends every field, with an empty filter for every event")
    func createSendsBody() async throws {
        let backend = Backend()
        let (store, _, _) = store(backend)
        await store.load()

        let created = await store.create(WebhookDraft(name: " deploys ", url: " https://hooks.example.com/render ", isEnabled: true))

        let body = try #require(backend.bodies.last?.body)
        #expect(body["ownerId"] as? String == "tea-1")
        #expect(body["name"] as? String == "deploys")
        #expect(body["url"] as? String == "https://hooks.example.com/render")
        #expect(body["enabled"] as? Bool == true)
        #expect((body["eventFilter"] as? [String]) == [])
        #expect(created?.receivesAllEvents == true)
        #expect(store.webhooks.map(\.name) == ["deploys"])
    }

    @Test("a chosen filter is sent in Render's order")
    func createSendsFilterInOrder() async throws {
        let backend = Backend()
        let (store, _, _) = store(backend)
        await store.load()

        await store.create(WebhookDraft(name: "d", url: "https://hooks.example.com/x", eventFilter: ["server_failed", "deploy_ended"]))

        let sent = try #require(backend.bodies.last?.body["eventFilter"] as? [String])
        let order = WebhookEventType.all
        #expect(Set(sent) == ["server_failed", "deploy_ended"])
        #expect(sent == sent.sorted { order.firstIndex(of: $0)! < order.firstIndex(of: $1)! })
    }

    @Test("an update sends only what changed")
    func updateSendsChanges() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([Self.webhookJSON(filter: #"["deploy_ended"]"#)]))
        let (store, _, _) = store(backend)
        await store.load()
        let original = try #require(store.webhooks.first)

        var draft = WebhookDraft(original)
        draft.isEnabled = false
        await store.update(original, to: draft)

        let body = try #require(backend.bodies.last?.body)
        #expect(body.keys.sorted() == ["enabled"])
        #expect(body["enabled"] as? Bool == false)
        #expect(store.actionResult?.message == "Webhook off.")
        #expect(store.webhooks.first?.isEnabled == false)
    }

    @Test("an update that clears a filter is never sent")
    func clearingFilterNotSent() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([Self.webhookJSON(filter: #"["deploy_ended"]"#)]))
        let (store, _, _) = store(backend)
        await store.load()
        let original = try #require(store.webhooks.first)

        var draft = WebhookDraft(original)
        draft.eventFilter = []
        let saved = await store.update(original, to: draft)

        #expect(!saved)
        #expect(backend.bodies.isEmpty)
    }

    @Test("a write Render refuses shows its reason")
    func writeRefused() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([Self.webhookJSON()]))
        backend.write = (400, #"{"message":"webhook URL must use https"}"#)
        let (store, _, _) = store(backend)
        await store.load()
        let original = try #require(store.webhooks.first)

        var draft = WebhookDraft(original)
        draft.name = "renamed"
        let saved = await store.update(original, to: draft)

        #expect(!saved)
        #expect(store.actionResult?.message == "Webhook URL must use https.")
        #expect(store.webhooks.first?.name == "deploys")
    }

    @Test("deleting removes the webhook, and a refresh from before can't bring it back")
    func deleteAndStaleRefresh() async throws {
        let backend = Backend()
        backend.list = (200, Self.listJSON([Self.webhookJSON(id: "whk-1", name: "a"), Self.webhookJSON(id: "whk-2", name: "b")]))
        let (store, transport, _) = store(backend)
        await store.load()

        let gate = Gate()
        backend.holdNextList(at: gate)
        let refresh = Task { await store.load() }
        await gate.waitUntilEntered()

        let deleted = await store.delete(try #require(store.webhook(id: "whk-1")))
        #expect(deleted)
        #expect(transport.requests.contains { $0.method == .delete && ($0.path ?? "").hasSuffix("/webhooks/whk-1") })

        await gate.open()
        await refresh.value
        #expect(store.webhooks.map(\.id) == ["whk-2"], "the older list must not win")
    }

    // MARK: - Deliveries

    @Test("deliveries decode an unknown event type, a failed status and a timeout, a page at a time")
    func deliveries() async throws {
        let backend = Backend()
        backend.deliveries = (200, "[" + [
            Self.deliveryJSON("whe-1", type: "deploy_ended", status: 200),
            Self.deliveryJSON("whe-2", type: "something_brand_new", status: 405),
        ].joined(separator: ",") + "]")
        backend.nextDeliveries = (cursor: "c-whe-2", answer: (200, "[" + Self.deliveryJSON("whe-3", type: "server_failed", status: nil, error: "timeout") + "]"))
        let (_, _, client) = store(backend)
        let deliveries = WebhookDeliveriesStore(client: client, webhookID: "whk-1", pageSize: 2)

        await deliveries.load()
        #expect(deliveries.errorMessage == nil)
        #expect(deliveries.deliveries.map(\.outcome) == ["200", "405"])
        #expect(deliveries.deliveries.map(\.succeeded) == [true, false])
        #expect(deliveries.deliveries[1].eventType == "something_brand_new")
        #expect(deliveries.hasMore)

        await deliveries.loadMore()
        #expect(deliveries.deliveries.map(\.id) == ["whe-1", "whe-2", "whe-3"])
        #expect(deliveries.deliveries[2].outcome == "Failed: timeout")
        #expect(!deliveries.hasMore)
    }
}
