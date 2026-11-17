import RenderAPI
import SwiftUI

/// The workspace's webhooks, presented from the account menu.
struct WebhooksView: View {
    @State private var store: WebhooksStore
    @State private var isCreating = false
    @Environment(\.dismiss) private var dismiss

    private let client: RenderClient

    init(client: RenderClient, ownerID: String) {
        self.client = client
        _store = State(initialValue: WebhooksStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        NavigationStack {
            List {
                if store.hasLoaded {
                    if let message = store.errorMessage {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    if store.webhooks.isEmpty, store.errorMessage == nil {
                        ContentUnavailableView(
                            "No Webhooks",
                            systemImage: "point.3.connected.trianglepath.dotted",
                            description: Text("A webhook sends this workspace's events to a URL you choose.")
                        )
                    }
                    ForEach(store.webhooks) { webhook in
                        NavigationLink {
                            WebhookDetailView(store: store, client: client, webhookID: webhook.id)
                        } label: {
                            WebhookRow(webhook: webhook)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Webhooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("New Webhook", systemImage: "plus") { isCreating = true }
                        .disabled(!store.hasLoaded || store.isSaving)
                }
            }
            .task { await store.load() }
            .refreshable { await store.load() }
            .safeAreaInset(edge: .bottom) { WebhookActionBanner(store: store) }
            .actionOutcomeFeedback(store.actionResult)
            .sheet(isPresented: $isCreating) {
                WebhookEditSheet(original: nil) { draft in
                    Task { await store.create(draft) }
                }
            }
        }
    }
}

private struct WebhookRow: View {
    let webhook: Webhook

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(webhook.name.isEmpty ? "Untitled" : webhook.name)
                    .lineLimit(1)
                if !webhook.isEnabled {
                    MiniBadge(title: "Off")
                }
            }
            Text(webhook.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(webhook.receivesAllEvents ? "Every event" : "\(webhook.eventFilter.count) event type\(webhook.eventFilter.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// The outcome of the last create, update or delete.
struct WebhookActionBanner: View {
    let store: WebhooksStore

    var body: some View {
        if let result = store.actionResult {
            HStack(spacing: 8) {
                Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(result.message)
                    .font(.subheadline)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { store.dismissActionResult() }
                    .labelStyle(.iconOnly)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(result.isFailure ? .red : .green)
            .padding(.horizontal)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One webhook: whether it's on, where it sends, which events, its secret, and recent deliveries.
struct WebhookDetailView: View {
    let store: WebhooksStore
    @State private var deliveries: WebhookDeliveriesStore
    @State private var isEditing = false
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    private let webhookID: String

    init(store: WebhooksStore, client: RenderClient, webhookID: String) {
        self.store = store
        self.webhookID = webhookID
        _deliveries = State(initialValue: WebhookDeliveriesStore(client: client, webhookID: webhookID))
    }

    var body: some View {
        List {
            if let webhook = store.webhook(id: webhookID) {
                settingsSection(webhook)
                eventsSection(webhook)
                deliveriesSection
                Section {
                    Button("Delete Webhook", systemImage: "trash", role: .destructive) {
                        isConfirmingDelete = true
                    }
                    .disabled(store.isSaving)
                }
            } else {
                ContentUnavailableView("Webhook Deleted", systemImage: "trash")
            }
        }
        .navigationTitle(store.webhook(id: webhookID).map { $0.name.isEmpty ? "Untitled" : $0.name } ?? "Webhook")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { isEditing = true }
                    .disabled(store.webhook(id: webhookID) == nil || store.isSaving)
            }
        }
        .task { await deliveries.load() }
        .refreshable {
            await store.load()
            await deliveries.load()
        }
        .safeAreaInset(edge: .bottom) { WebhookActionBanner(store: store) }
        .sheet(isPresented: $isEditing) {
            if let webhook = store.webhook(id: webhookID) {
                WebhookEditSheet(original: webhook) { draft in
                    Task { await store.update(webhook, to: draft) }
                }
            }
        }
        .confirmationDialog(
            "Delete this webhook?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Webhook", role: .destructive) {
                guard let webhook = store.webhook(id: webhookID) else { return }
                Task {
                    if await store.delete(webhook) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Render stops sending events to this URL. Anything that relies on them stops getting them.")
        }
    }

    private func settingsSection(_ webhook: Webhook) -> some View {
        Section {
            Toggle("On", isOn: Binding(
                get: { webhook.isEnabled },
                set: { isOn in
                    var draft = WebhookDraft(webhook)
                    draft.isEnabled = isOn
                    Task { await store.update(webhook, to: draft) }
                }
            ))
            .disabled(store.isSaving)
            LabeledContent("URL") {
                Text(webhook.url)
                    .font(.caption.monospaced())
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
            }
            LabeledContent("Signing Secret") {
                SecretValueView(value: webhook.secret)
            }
        } footer: {
            Text("Render signs each delivery with the secret, so the receiver can check it came from Render.")
        }
    }

    private func eventsSection(_ webhook: Webhook) -> some View {
        Section("Events") {
            if webhook.receivesAllEvents {
                Text("Every event")
            } else {
                ForEach(webhook.eventFilter, id: \.self) { type in
                    Text(WebhookEventType.displayName(type))
                }
            }
        }
    }

    @ViewBuilder
    private var deliveriesSection: some View {
        Section {
            if let message = deliveries.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if deliveries.hasLoaded {
                if deliveries.deliveries.isEmpty, deliveries.errorMessage == nil {
                    Text("Nothing sent yet.").foregroundStyle(.secondary)
                }
                ForEach(deliveries.deliveries) { delivery in
                    DeliveryRow(delivery: delivery)
                }
                if deliveries.hasMore {
                    Button("Show More") { Task { await deliveries.loadMore() } }
                        .disabled(deliveries.isLoading)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("Recent Deliveries")
        }
    }
}

private struct DeliveryRow: View {
    let delivery: WebhookDelivery

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WebhookEventType.displayName(delivery.eventType))
                Text(delivery.sentAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(delivery.outcome, systemImage: delivery.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(delivery.succeeded ? .green : .red)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// Creates or edits a webhook.
struct WebhookEditSheet: View {
    let original: Webhook?
    let onSave: (WebhookDraft) -> Void

    @State private var draft: WebhookDraft
    @State private var choosesEvents: Bool
    @Environment(\.dismiss) private var dismiss
    /// The draft as the sheet opened, so a problem is only spelled out once something's been changed.
    private let initial: WebhookDraft

    init(original: Webhook?, onSave: @escaping (WebhookDraft) -> Void) {
        self.original = original
        self.onSave = onSave
        let draft = original.map(WebhookDraft.init) ?? WebhookDraft()
        initial = draft
        _draft = State(initialValue: draft)
        _choosesEvents = State(initialValue: !draft.eventFilter.isEmpty)
    }

    /// A webhook that already has a filter can't go back to every event: Render ignores an empty
    /// filter on an update.
    private var canChooseEveryEvent: Bool { original?.receivesAllEvents ?? true }

    private var submitted: WebhookDraft {
        var submitted = draft
        if !choosesEvents { submitted.eventFilter = [] }
        return submitted
    }

    private var problem: String? {
        submitted.validationMessage(editing: original)
            ?? (choosesEvents && draft.eventFilter.isEmpty ? "Choose at least one event." : nil)
    }

    private var groups: [(name: String, types: [String])] {
        Dictionary(grouping: WebhookEventType.all, by: WebhookEventType.group)
            .map { (name: $0.key, types: $0.value) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    TextField("https://", text: $draft.url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    Toggle("On", isOn: $draft.isEnabled)
                }

                Section {
                    Picker("Send", selection: $choosesEvents) {
                        Text("Every event").tag(false)
                        Text("Chosen events").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!canChooseEveryEvent)
                } footer: {
                    if !canChooseEveryEvent {
                        Text("Render can't remove a filter from an existing webhook. To send every event, change it in the Render Dashboard or create a new webhook.")
                    }
                }

                if choosesEvents {
                    ForEach(groups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.types, id: \.self) { type in
                                Toggle(WebhookEventType.displayName(type), isOn: Binding(
                                    get: { draft.eventFilter.contains(type) },
                                    set: { isOn in
                                        if isOn { draft.eventFilter.insert(type) } else { draft.eventFilter.remove(type) }
                                    }
                                ))
                            }
                        }
                    }
                }

                if draft != initial, let message = problem {
                    Section {
                        Text(message).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(original == nil ? "New Webhook" : "Edit Webhook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(original == nil ? "Create" : "Save") {
                        dismiss()
                        onSave(submitted)
                    }
                    .disabled(problem != nil)
                }
            }
        }
    }
}
