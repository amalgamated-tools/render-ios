import RenderAPI
import SwiftUI

/// A service's redirect and rewrite rules, in the order the service evaluates them.
///
/// The order *is* the behaviour — first match wins — so the list is numbered and the only edit offered
/// on an existing rule is moving it. A screen that showed these rules unordered would be describing a
/// different service than the one running.
struct RouteRulesView: View {
    @State private var store: RouteRulesStore
    @State private var isAdding = false
    @State private var pendingDeletion: RouteRuleEntry?

    init(client: RenderClient, serviceID: String, deployer: ConfigDeployer? = nil) {
        _store = State(
            initialValue: RouteRulesStore(client: client, serviceID: serviceID, deployer: deployer)
        )
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.rules.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(Array(store.sortedRules.enumerated()), id: \.element.id) { position, rule in
                    row(for: rule, at: position)
                }
            } footer: {
                if !store.rules.isEmpty {
                    Text("Evaluated top to bottom; the first match wins. A rule can't be edited — remove it and add the replacement.")
                }
            }
        }
        .navigationTitle("Redirects & Rewrites")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Rule", systemImage: "plus") { isAdding = true }
                    .disabled(store.writeInFlight != nil)
            }
        }
        .overlay { emptyOrErrorState }
        .safeAreaInset(edge: .bottom) { banner }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(isPresented: $isAdding) {
            RouteRuleAddSheet(store: store)
        }
        .confirmationDialog(
            "Remove this rule?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { rule in
            Button("Remove", role: .destructive) {
                Task { await store.delete(rule) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { rule in
            Text("\(rule.source) stops being \(rule.isRedirect ? "redirected" : "rewritten"). \(ConfigScope.service.takesEffectNote)")
        }
    }

    private func row(for rule: RouteRuleEntry, at position: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("\(position + 1)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(rule.isRedirect ? "Redirect" : "Rewrite")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (rule.isRedirect ? Color.orange : Color.blue).opacity(0.15),
                        in: Capsule()
                    )
                    .foregroundStyle(rule.isRedirect ? .orange : .blue)
                Spacer()
                if store.writeInFlight == rule.id || store.writeInFlight == rule.source {
                    ProgressView()
                }
            }
            Text(rule.source)
                .font(.system(.subheadline, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Label(rule.destination, systemImage: "arrow.turn.down.right")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                pendingDeletion = rule
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            // Reordering is the reason to come back to this screen, so it's one swipe away rather than
            // buried in an edit mode.
            if position > 0 {
                Button("Up", systemImage: "arrow.up") {
                    Task { await store.move(rule, direction: .up) }
                }
                .tint(.indigo)
            }
            if position < store.sortedRules.count - 1 {
                Button("Down", systemImage: "arrow.down") {
                    Task { await store.move(rule, direction: .down) }
                }
                .tint(.indigo)
            }
        }
        .disabled(store.writeInFlight != nil)
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.rules.isEmpty {
            if let message = store.errorMessage {
                ErrorStateView(subject: "rules", message: message) { await store.refresh() }
            } else if store.isLoading {
                SkeletonList()
            } else {
                ContentUnavailableView {
                    Label("No Redirects or Rewrites", systemImage: "arrow.triangle.branch")
                } description: {
                    Text("Requests are served from the paths they ask for.")
                }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let result = store.actionResult {
            ConfigResultBanner(
                result: result,
                deployer: store.deployer,
                deploy: { await store.deployNow() },
                dismiss: { store.dismissActionResult() }
            )
        }
    }
}

/// Adds a redirect or a rewrite.
struct RouteRuleAddSheet: View {
    let store: RouteRulesStore

    @State private var type: Components.Schemas.RouteType = .redirect
    @State private var source = ""
    @State private var destination = ""
    @Environment(\.dismiss) private var dismiss

    private var problem: String? {
        let source = source.trimmingCharacters(in: .whitespaces)
        let destination = destination.trimmingCharacters(in: .whitespaces)
        if !source.isEmpty, !source.hasPrefix("/") { return "The source path starts with “/”." }
        // A rewrite is internal, so its destination has to be a path on this service; a redirect may
        // legitimately point at another host.
        if type == .rewrite, !destination.isEmpty, destination.contains("://") {
            return "A rewrite serves a path on this service. Use a redirect to send traffic elsewhere."
        }
        if !source.isEmpty, source == destination { return "The source and destination are the same." }
        return nil
    }

    private var canSave: Bool {
        !source.trimmingCharacters(in: .whitespaces).isEmpty
            && !destination.trimmingCharacters(in: .whitespaces).isEmpty
            && problem == nil
            && store.writeInFlight == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $type) {
                        Text("Redirect").tag(Components.Schemas.RouteType.redirect)
                        Text("Rewrite").tag(Components.Schemas.RouteType.rewrite)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(
                        type == .redirect
                            ? "A redirect sends the browser to the destination, and the URL changes."
                            : "A rewrite serves the destination's content at the original URL."
                    )
                }

                Section("Source") {
                    TextField("/old-path", text: $source)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                Section("Destination") {
                    TextField(type == .redirect ? "/new-path or https://example.com" : "/index.html", text: $destination)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Add Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.writeInFlight != nil {
                        ProgressView()
                    } else {
                        Button("Add") {
                            Task {
                                if await store.add(type: type, source: source, destination: destination) {
                                    dismiss()
                                }
                            }
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
    }
}
