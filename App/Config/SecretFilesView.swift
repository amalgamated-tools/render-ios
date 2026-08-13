import RenderAPI
import SwiftUI

/// A service's secret files: list, edit contents, add, delete.
///
/// The list shows a name and a size, never contents. A secret file is usually a key or a
/// credentials blob, and the reason it's a *file* rather than a variable is that it's long — so
/// showing it inline would both leak it and fill the screen. Contents live behind the editor, and
/// behind a reveal there.
struct SecretFilesView: View {
    @State private var store: SecretFilesStore
    @State private var isAddingFile = false
    @State private var pendingDeletion: SecretFileEntry?

    init(client: RenderClient, serviceID: String, deployer: ConfigDeployer? = nil) {
        _store = State(
            initialValue: SecretFilesStore(client: client, serviceID: serviceID, deployer: deployer)
        )
    }

    /// The same screen over an env group's secret files. No deployer — see ``ConfigScope``.
    init(backend: SecretFileBackend) {
        _store = State(initialValue: SecretFilesStore(backend: backend))
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.files.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(store.sortedFiles) { file in
                NavigationLink {
                    SecretFileEditor(file: file, store: store)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name)
                            .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(file.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        pendingDeletion = file
                    }
                }
                .disabled(store.writeInFlight != nil)
            }
        }
        .navigationTitle("Secret Files")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add File", systemImage: "plus") { isAddingFile = true }
                    .disabled(store.writeInFlight != nil)
            }
        }
        .overlay { emptyOrErrorState }
        .safeAreaInset(edge: .bottom) { banner }
        .sheet(isPresented: $isAddingFile) {
            NavigationStack {
                SecretFileEditor(file: nil, store: store)
            }
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "")?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { file in
            Button("Delete", role: .destructive) {
                Task { await store.delete(name: file.name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(store.scope.takesEffectNote)
        }
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.files.isEmpty {
            if let message = store.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load secret files", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await store.refresh() } }
                }
            } else if store.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Secret Files", systemImage: "doc.text")
                } description: {
                    Text(store.scope.emptySecretFilesDescription)
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

/// Edits one secret file, or creates one when `file` is nil.
///
/// Contents start hidden even here. Opening a file to check its name — the common reason to come to
/// this screen — shouldn't put a private key on the display.
struct SecretFileEditor: View {
    let file: SecretFileEntry?
    let store: SecretFilesStore

    @State private var name = ""
    @State private var content = ""
    @State private var isRevealed = false
    @Environment(\.dismiss) private var dismiss

    private var isNew: Bool { file == nil }

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if isNew, store.containsName(trimmed) { return "\(trimmed) already exists — saving will overwrite it." }
        return nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && store.writeInFlight == nil
            && (isNew || content != file?.content || name != file?.name)
    }

    var body: some View {
        Form {
            Section {
                if isNew {
                    TextField("credentials.json", text: $name)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    // Plain text rather than a disabled field, which reads as an empty one.
                    Text(name)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("File Name")
            } footer: {
                if !isNew {
                    Text("A file can't be renamed. Delete it and add the new one instead.")
                }
            }

            Section {
                if isRevealed || isNew {
                    TextEditor(text: $content)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 220)
                        .privacySensitive()
                } else {
                    Button("Reveal contents", systemImage: "eye") { isRevealed = true }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(file?.summary ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Contents")
            } footer: {
                // As with env vars: an API write changes the configuration without deploying.
                Text("Saving replaces the file. \(store.scope.takesEffectNote)")
            }

            if let problem = nameProblem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle(isNew ? "Add Secret File" : (file?.name ?? ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if store.writeInFlight != nil {
                    ProgressView()
                } else {
                    Button("Save") {
                        Task {
                            if await store.save(name: name, content: content) { dismiss() }
                        }
                    }
                    .disabled(!canSave)
                }
            }
        }
        .onAppear {
            guard let file else { return }
            name = file.name
            content = file.content
        }
    }
}
