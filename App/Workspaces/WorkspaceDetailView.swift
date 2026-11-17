import RenderAPI
import SwiftUI

/// The workspace's details and members, with the audit log one level down. Presented from the
/// account menu.
struct WorkspaceDetailView: View {
    @State private var store: WorkspaceMembersStore
    @State private var memberToRemove: WorkspaceMember?
    @State private var roleChange: (member: WorkspaceMember, role: MemberRole)?
    @Environment(\.dismiss) private var dismiss

    private let client: RenderClient
    /// Who's signed in. Their own row offers no actions, and nobody can be managed until it's known.
    private let accountStore: AccountStore
    private var currentUserID: String? { accountStore.user?.id }

    init(client: RenderClient, ownerID: String, accountStore: AccountStore) {
        self.client = client
        self.accountStore = accountStore
        _store = State(initialValue: WorkspaceMembersStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        NavigationStack {
            List {
                if store.hasLoaded {
                    workspaceSection
                    membersSection
                    Section {
                        NavigationLink {
                            AuditLogView(client: client, ownerID: store.ownerID)
                        } label: {
                            Label("Audit Log", systemImage: "list.bullet.clipboard")
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .navigationTitle(store.workspace?.name ?? "Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // The account loads once at launch and gives up quietly; try again here, or member
                // actions would stay off for the rest of the session.
                async let account: Void = accountStore.user == nil ? accountStore.load() : ()
                await store.load()
                await account
            }
            .refreshable {
                async let account: Void = accountStore.user == nil ? accountStore.load() : ()
                await store.load()
                await account
            }
            .safeAreaInset(edge: .bottom) { actionBanner }
            .actionOutcomeFeedback(store.actionResult)
            .confirmationDialog(
                memberToRemove.map { "Remove \(Self.label($0))?" } ?? "",
                isPresented: .init(get: { memberToRemove != nil }, set: { if !$0 { memberToRemove = nil } }),
                titleVisibility: .visible,
                presenting: memberToRemove
            ) { member in
                Button("Remove \(Self.label(member))", role: .destructive) {
                    Task { await store.remove(member, currentUserID: currentUserID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { member in
                Text("\(Self.label(member)) loses access to everything in this workspace.")
            }
            .confirmationDialog(
                roleChange.map { "Make \(Self.label($0.member)) \($0.role.displayName)?" } ?? "",
                isPresented: .init(get: { roleChange != nil }, set: { if !$0 { roleChange = nil } }),
                titleVisibility: .visible,
                presenting: roleChange
            ) { change in
                Button("Make \(change.role.displayName)") {
                    Task { await store.changeRole(of: change.member, to: change.role, currentUserID: currentUserID) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { change in
                Text("Changes what \(Self.label(change.member)) can do in this workspace, from \(change.member.role.displayName) to \(change.role.displayName).")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var workspaceSection: some View {
        Section {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if let workspace = store.workspace {
                LabeledContent("Name", value: workspace.name)
                LabeledContent("Type", value: workspace.isTeam ? "Team" : "Personal")
                LabeledContent("IP Allow List", value: workspace.ipAllowListCount == 0
                    ? "Everywhere"
                    : "\(workspace.ipAllowListCount) rule\(workspace.ipAllowListCount == 1 ? "" : "s")")
                if let isTwoFactorEnabled = workspace.isTwoFactorEnabled {
                    LabeledContent("Two-Factor Authentication", value: isTwoFactorEnabled ? "On" : "Off")
                }
            }
        }
    }

    @ViewBuilder
    private var membersSection: some View {
        Section {
            if let message = store.membersErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            ForEach(store.members) { member in
                memberRow(member)
                    .swipeActions {
                        if store.canManage(member, currentUserID: currentUserID) {
                            Button("Remove", systemImage: "person.badge.minus", role: .destructive) {
                                memberToRemove = member
                            }
                            .disabled(store.writeInFlight != nil)
                        }
                    }
                    .contextMenu {
                        if store.canManage(member, currentUserID: currentUserID) {
                            roleMenu(for: member)
                        }
                    }
            }
        } header: {
            Text("Members")
        } footer: {
            Text("Touch and hold a member to change their role, or swipe to remove them. You can't change your own access from here.")
        }
    }

    @ViewBuilder
    private func roleMenu(for member: WorkspaceMember) -> some View {
        ForEach(MemberRole.assignable, id: \.self) { role in
            Button {
                roleChange = (member, role)
            } label: {
                if role == member.role {
                    Label(role.displayName, systemImage: "checkmark")
                } else {
                    Text(role.displayName)
                }
            }
            .disabled(role == member.role || store.writeInFlight != nil)
        }
    }

    private func memberRow(_ member: WorkspaceMember) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(member.name.isEmpty ? member.email : member.name)
                    .lineLimit(1)
                if member.userID == currentUserID {
                    MiniBadge(title: "You")
                }
                if !member.isActive {
                    MiniBadge(title: "Inactive")
                }
                Spacer()
                if store.writeInFlight == member.userID {
                    ProgressView()
                }
            }
            HStack(spacing: 4) {
                Text(member.role.displayName)
                Text("·")
                Text(member.isMFAEnabled ? "2FA on" : "2FA off")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !member.name.isEmpty {
                Text(member.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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

    private static func label(_ member: WorkspaceMember) -> String {
        member.name.isEmpty ? member.email : member.name
    }
}

/// The workspace's audit log, newest first.
struct AuditLogView: View {
    @State private var store: AuditLogStore

    init(client: RenderClient, ownerID: String) {
        _store = State(initialValue: AuditLogStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        List {
            if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
            if store.hasLoaded {
                if store.entries.isEmpty, store.errorMessage == nil {
                    ContentUnavailableView("No Entries", systemImage: "list.bullet.clipboard",
                                           description: Text("Nothing has been recorded for this workspace recently."))
                }
                Section {
                    ForEach(store.entries) { entry in
                        NavigationLink {
                            AuditLogEntryView(entry: entry)
                        } label: {
                            AuditLogRow(entry: entry)
                        }
                    }
                    if store.hasMore {
                        Button("Show More") { Task { await store.loadMore() } }
                            .disabled(store.isLoading)
                    }
                } footer: {
                    if !store.entries.isEmpty {
                        Text("Render keeps the audit log for a limited time, so older actions may not appear.")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Audit Log")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
    }
}

private struct AuditLogRow: View {
    let entry: AuditLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(entry.title)
                    .lineLimit(1)
                switch entry.outcome {
                case .succeeded: EmptyView()
                case .failed: MiniBadge(title: "Failed")
                case .other: MiniBadge(title: entry.outcome.title)
                }
            }
            Text("\(entry.actorDescription) · \(entry.timestamp.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// Everything Render recorded for one entry.
private struct AuditLogEntryView: View {
    let entry: AuditLogEntry

    var body: some View {
        List {
            Section {
                LabeledContent("Action", value: entry.title)
                LabeledContent("Result", value: entry.outcome.title)
                LabeledContent("When", value: entry.timestamp.formatted(date: .abbreviated, time: .standard))
                LabeledContent("By", value: entry.actorDescription)
            }
            if !entry.metadata.isEmpty {
                Section("Details") {
                    ForEach(entry.metadata, id: \.key) { item in
                        LabeledContent(AuditLogEntryView.label(for: item.key)) {
                            Text(item.value)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// `source_ip` → "Source IP".
    static func label(for key: String) -> String {
        key.split(separator: "_").map { word in
            ["ip", "id", "url"].contains(word.lowercased()) ? word.uppercased() : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
