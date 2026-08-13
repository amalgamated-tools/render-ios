import RenderAPI
import SwiftUI

/// A service's response header rules: which headers get added, and to what paths.
struct HeaderRulesView: View {
    @State private var store: HeaderRulesStore
    @State private var isAdding = false
    @State private var pendingDeletion: HeaderRuleEntry?

    init(client: RenderClient, serviceID: String, deployer: ConfigDeployer? = nil) {
        _store = State(
            initialValue: HeaderRulesStore(client: client, serviceID: serviceID, deployer: deployer)
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
                ForEach(store.sortedRules) { rule in
                    row(for: rule)
                }
            } footer: {
                if !store.rules.isEmpty {
                    // Says out loud what the missing edit affordance means, rather than leaving the
                    // user to hunt for it.
                    Text("A rule can't be edited. Remove it and add the replacement.")
                }
            }
        }
        .navigationTitle("Headers")
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
            HeaderRuleAddSheet(store: store)
        }
        .confirmationDialog(
            "Remove \(pendingDeletion?.name ?? "")?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { rule in
            Button("Remove", role: .destructive) {
                Task { await store.delete(rule) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ConfigScope.service.takesEffectNote)
        }
    }

    private func row(for rule: HeaderRuleEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(rule.name)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                Spacer()
                if store.writeInFlight == rule.id || store.writeInFlight == rule.name {
                    ProgressView()
                }
            }
            Text(rule.value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Text("on \(rule.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                pendingDeletion = rule
            }
        }
        .disabled(store.writeInFlight != nil)
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.rules.isEmpty {
            if let message = store.errorMessage {
                ErrorStateView(subject: "header rules", message: message) { await store.refresh() }
            } else if store.isLoading {
                SkeletonList()
            } else {
                ContentUnavailableView {
                    Label("No Header Rules", systemImage: "text.append")
                } description: {
                    Text("Responses go out with Render's default headers only.")
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

/// Adds a header rule.
struct HeaderRuleAddSheet: View {
    let store: HeaderRulesStore

    @State private var path = "/*"
    @State private var name = ""
    @State private var value = ""
    @Environment(\.dismiss) private var dismiss

    private var pathProblem: String? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Render matches paths from the site root; a rule that doesn't start with "/" matches nothing,
        // which is a silent no-op rather than an error at the API.
        return trimmed.hasPrefix("/") ? nil : "A path pattern starts with “/”."
    }

    private var canSave: Bool {
        !path.trimmingCharacters(in: .whitespaces).isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && pathProblem == nil
            && store.writeInFlight == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("/*", text: $path)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Path Pattern")
                } footer: {
                    Text("/* applies to every response. Patterns match from the site root.")
                }

                Section("Header") {
                    TextField("X-Frame-Options", text: $name)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("DENY", text: $value)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }

                if let problem = pathProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Add Header Rule")
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
                                if await store.add(path: path, name: name, value: value) { dismiss() }
                            }
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
    }
}
