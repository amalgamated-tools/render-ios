import RenderAPI
import SwiftUI

/// A service's environment variables: read, edit, add, delete.
///
/// Nothing saves as you type — edits happen in a sheet with an explicit Save, and deletes go through
/// a confirmation. That's the same bar the Phase 2 lifecycle actions set, for the same reason: this
/// is a production service and the phone is a lousy place to make an accident. Writes change the
/// configuration without deploying, so every success says when the change actually takes effect.
struct EnvVarsView: View {
    @State private var store: EnvVarsStore
    /// Non-nil while the editor is up. `.new` adds; `.existing` edits a key that can't be renamed.
    @State private var editing: EnvVarEditor.Subject?
    @State private var pendingDeletion: EnvVarEntry?

    init(client: RenderClient, serviceID: String, deployer: ConfigDeployer? = nil) {
        _store = State(
            initialValue: EnvVarsStore(client: client, serviceID: serviceID, deployer: deployer)
        )
    }

    /// The same screen over an env group's variables. No deployer: a group feeds every service linked
    /// to it, so one tap can't honestly make the change live — see ``ConfigScope``.
    init(backend: EnvVarBackend) {
        _store = State(initialValue: EnvVarsStore(backend: backend))
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.entries.isEmpty {
                // The list still has content, so the failure is a note rather than a takeover.
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(store.visibleEntries) { entry in
                row(for: entry)
            }
        }
        .navigationTitle("Environment")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $store.searchText, placement: .navigationBarDrawer, prompt: "Search keys")
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Variable", systemImage: "plus") { editing = .new }
                    .disabled(store.writeInFlight != nil)
            }
        }
        .overlay { emptyOrErrorState }
        .safeAreaInset(edge: .bottom) { banner }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(item: $editing) { subject in
            EnvVarEditor(subject: subject, store: store)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.key ?? "")?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                Task { await store.delete(key: entry.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(store.scope.takesEffectNote)
        }
    }

    private func row(for entry: EnvVarEntry) -> some View {
        Button {
            editing = .existing(entry)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.key)
                        .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if store.writeInFlight == entry.key {
                        ProgressView()
                    }
                }
                SecretValueView(value: entry.value)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Never full-swipe: this is destructive and needs the confirmation to be seen.
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = entry
            }
        }
        .disabled(store.writeInFlight != nil)
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.entries.isEmpty {
            if let message = store.errorMessage {
                ErrorStateView(subject: "environment variables", message: message) { await store.refresh() }
            } else if store.isLoading {
                SkeletonList()
            } else {
                ContentUnavailableView {
                    Label("No Environment Variables", systemImage: "key")
                } description: {
                    Text(store.scope.emptyEnvVarsDescription)
                }
            }
        } else if store.visibleEntries.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
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

/// Adds or edits one variable.
///
/// A key can't be renamed: Render addresses variables by key, so a rename is a delete plus a create,
/// and doing that silently from a phone would leave a half-applied config behind if the second call
/// failed. Renaming is delete-then-add, deliberately explicit.
struct EnvVarEditor: View {
    enum Subject: Identifiable {
        case new
        case existing(EnvVarEntry)

        var id: String {
            switch self {
            case .new: "new"
            case .existing(let entry): entry.key
            }
        }
    }

    let subject: Subject
    let store: EnvVarsStore

    @State private var key = ""
    @State private var value = ""
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool {
        if case .new = subject { return true }
        return false
    }

    /// A key Render will accept: no whitespace and no `=`, which are the two ways a shell-shaped
    /// habit ("KEY = value") turns into a variable nothing reads.
    private var keyProblem: String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.contains("=") { return "A key can't contain “=”." }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return "A key can't contain spaces." }
        if isNew, store.containsKey(trimmed) { return "\(trimmed) already exists — editing it will overwrite the current value." }
        return nil
    }

    /// The original value, so an unchanged edit can't spend a write on the value that's already
    /// there.
    private var originalValue: String? {
        if case .existing(let entry) = subject { return entry.value }
        return nil
    }

    private var canSave: Bool {
        !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && keyProblem == nil
            && store.writeInFlight == nil
            && value != originalValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if isNew {
                        TextField("DATABASE_URL", text: $key)
                            .font(.system(.body, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        // Not a disabled TextField: a greyed-out field is indistinguishable from a
                        // placeholder, so the first live pass showed an editor that looked like it
                        // had lost the key it was editing.
                        Text(key)
                            .font(.system(.body, design: .monospaced))
                    }
                } header: {
                    Text("Key")
                } footer: {
                    if !isNew {
                        Text("A key can't be renamed. Delete it and add the new one instead.")
                    }
                }

                Section {
                    // A plain editor, not a `SecureField`, and that took two live passes to settle.
                    // A secure field prefilled with an existing value clears itself on the first
                    // keystroke — so "append -2 to phase5a" saved exactly "-2" — and iOS reads any
                    // secure field as a credential, offering to save the value to the user's
                    // keychain when the sheet closes (`.textContentType(.oneTimeCode)` doesn't stop
                    // it). Neither is acceptable for a config value. The masking that matters
                    // happens in the list; getting here at all takes a deliberate tap on the row.
                    TextEditor(text: $value)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 96)
                        .privacySensitive()
                } header: {
                    Text("Value")
                } footer: {
                    // Verified live: an env var written through the API changes the configuration
                    // but starts no deploy, unlike the same edit made in the dashboard.
                    Text("Saving replaces the current value. \(store.scope.takesEffectNote)")
                }

                if let problem = keyProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle(isNew ? "Add Variable" : key)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.writeInFlight != nil {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                // Dismiss only on success, so a rejected value isn't lost along
                                // with the sheet that holds it.
                                if await store.save(key: key, value: value) { dismiss() }
                            }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear {
                if case .existing(let entry) = subject {
                    key = entry.key
                    value = entry.value
                }
            }
        }
    }
}
