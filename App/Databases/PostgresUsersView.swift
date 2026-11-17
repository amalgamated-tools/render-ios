import RenderAPI
import SwiftUI

/// A Postgres database's users, for rotating its credentials: add a user, which becomes the default,
/// then delete the old one once nothing uses it.
struct PostgresUsersView: View {
    @State private var store: PostgresUsersStore
    @State private var isAddingUser = false
    @State private var userToDelete: PostgresUser?

    private let databaseName: String
    /// Called after a new user becomes the default, so the database screen can re-read its connection
    /// details.
    private let onDefaultUserChanged: () -> Void

    init(client: RenderClient, postgresID: String, databaseName: String, onDefaultUserChanged: @escaping () -> Void) {
        self.databaseName = databaseName
        self.onDefaultUserChanged = onDefaultUserChanged
        _store = State(initialValue: PostgresUsersStore(client: client, postgresID: postgresID))
    }

    var body: some View {
        List {
            if store.hasLoaded {
                usersSection
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Users")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add User", systemImage: "plus") {
                    isAddingUser = true
                }
                .disabled(!store.hasLoaded || store.writeInFlight != nil)
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(isPresented: $isAddingUser) {
            AddUserSheet(store: store, databaseName: databaseName) { username in
                Task {
                    if await store.add(username: username) { onDefaultUserChanged() }
                }
            }
        }
        .confirmationDialog(
            userToDelete.map { "Delete \($0.username)?" } ?? "",
            isPresented: .init(get: { userToDelete != nil }, set: { if !$0 { userToDelete = nil } }),
            titleVisibility: .visible,
            presenting: userToDelete
        ) { user in
            Button("Delete \(user.username)", role: .destructive) {
                Task { await store.delete(user) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { user in
            Text(deleteMessage(for: user))
        }
    }

    private func deleteMessage(for user: PostgresUser) -> String {
        let connections = user.openConnections == 1 ? "1 open connection" : "\(user.openConnections) open connections"
        return "Anything connecting as \(user.username) loses access. It has \(connections) right now."
    }

    // MARK: - Sections

    @ViewBuilder
    private var usersSection: some View {
        Section {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            ForEach(store.users) { user in
                row(for: user)
                    .swipeActions {
                        if !user.isDefault {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                userToDelete = user
                            }
                            .disabled(store.writeInFlight != nil)
                        }
                    }
            }
        } footer: {
            Text("To rotate credentials, add a user, move your services to the new connection details, then swipe to delete the old user. The default user can't be deleted.")
        }
    }

    private func row(for user: PostgresUser) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(user.username)
                    .font(.body.monospaced())
                    .lineLimit(1)
                if user.isDefault {
                    MiniBadge(title: "Default")
                }
                Spacer()
                if store.writeInFlight == user.username {
                    ProgressView()
                }
            }
            HStack(spacing: 4) {
                if let createdAt = user.createdAt {
                    Text("Created \(createdAt.formatted(.relative(presentation: .named)))")
                }
                Text("·")
                Text(user.openConnections == 1 ? "1 open connection" : "\(user.openConnections) open connections")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var actionBanner: some View {
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

/// Names a new user. A sheet rather than an alert, because an alert's message doesn't update while
/// it's open, so it couldn't say why Add is unavailable.
private struct AddUserSheet: View {
    let store: PostgresUsersStore
    let databaseName: String
    let onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var username = ""

    private var problem: String? {
        username.isEmpty ? nil : store.validationMessage(forNewUsername: username)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Render accepts only lowercase, so capitals are lowered as they're typed rather
                    // than refused.
                    TextField("username", text: Binding(get: { username }, set: { username = $0.lowercased() }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("Lowercase letters, digits and underscores.")
                    }
                }
                Section {
                } footer: {
                    Text("The new user becomes \(databaseName)'s default, and its connection details switch to it. Clients using the current user keep working until you delete it.")
                }
            }
            .navigationTitle("Add User")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        dismiss()
                        onSubmit(username)
                    }
                    .disabled(store.validationMessage(forNewUsername: username) != nil)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
