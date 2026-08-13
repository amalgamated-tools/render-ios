import RenderAPI
import SwiftUI

/// The workspace's env groups: the shared half of every service's configuration.
///
/// A tab rather than a drill-down, because a group isn't owned by any one service — the same group
/// feeds many, and the API has no service-side listing of them at all.
struct EnvGroupsListView: View {
    @State private var store: EnvGroupsStore
    @State private var isCreating = false
    @State private var pendingDeletion: EnvGroupSummary?

    private let client: RenderClient
    /// Passed down so the group screen can offer a service to link — the picker lists this workspace.
    private let ownerID: String

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
        _store = State(initialValue: EnvGroupsStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.groups.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                ForEach(store.visibleGroups) { group in
                    row(for: group)
                }
            } footer: {
                if !store.groups.isEmpty {
                    // Says the scope out loud rather than leaving the missing project filter to be
                    // inferred — see `EnvGroupsStore` for why there isn't one.
                    Text("Groups belong to the workspace, not to a project.")
                }
            }
        }
        .navigationTitle("Env Groups")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $store.searchText, placement: .navigationBarDrawer, prompt: "Search groups")
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New Group", systemImage: "plus") { isCreating = true }
                    .disabled(store.writeInFlight != nil)
            }
        }
        .overlay { emptyOrErrorState }
        .safeAreaInset(edge: .bottom) { banner }
        .sheet(isPresented: $isCreating) {
            EnvGroupCreateSheet(store: store)
        }
        .confirmationDialog(
            "Delete \(pendingDeletion?.name ?? "")?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { group in
            Button("Delete", role: .destructive) {
                Task { await store.delete(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            // The consequence, stated in terms of what breaks: every linked service loses these
            // variables at its next deploy. A count is the difference between a shrug and a pause.
            if group.linkedServiceCount == 0 {
                Text("This group has no linked services.")
            } else {
                Text("\(group.linkSummary) will lose these variables and files at their next deploy.")
            }
        }
    }

    private func row(for group: EnvGroupSummary) -> some View {
        NavigationLink {
            EnvGroupDetailView(client: client, group: group, ownerID: ownerID) { updated in
                store.apply(updated)
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(group.linkSummary)
                    if store.writeInFlight == group.id {
                        ProgressView()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            // Deleting a group can break several services at once, so it takes the same deliberate
            // reveal-then-tap as every other destructive action in the app.
            Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = group
            }
        }
        .disabled(store.writeInFlight != nil)
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.groups.isEmpty {
            if let message = store.errorMessage {
                ErrorStateView(subject: "environment groups", message: message) { await store.refresh() }
            } else if store.isLoading {
                SkeletonList()
            } else {
                ContentUnavailableView {
                    Label("No Environment Groups", systemImage: "rectangle.stack")
                } description: {
                    Text("A group holds variables and secret files shared by several services.")
                }
            }
        } else if store.visibleGroups.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let result = store.actionResult {
            // No deployer: creating or deleting a group is not one service's change to make live.
            ConfigResultBanner(
                result: result,
                deployer: nil,
                deploy: {},
                dismiss: { store.dismissActionResult() }
            )
        }
    }
}

/// Names a new, empty group.
///
/// Empty by design: the variables go in through the group's own screen, using the same editor that
/// edits them later. A create form that also collected variables would be a second editor to keep in
/// step with the first.
struct EnvGroupCreateSheet: View {
    let store: EnvGroupsStore

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if store.containsName(trimmed) { return "\(trimmed) already exists." }
        return nil
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && nameProblem == nil
            && store.writeInFlight == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("shared-config", text: $name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Name")
                } footer: {
                    Text("The group is created empty and linked to nothing. Add variables and link services from its screen.")
                }

                if let problem = nameProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("New Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.writeInFlight != nil {
                        ProgressView()
                    } else {
                        Button("Create") {
                            Task {
                                // Dismiss only on success, so a rejected name isn't lost with the sheet.
                                if await store.create(name: name) != nil { dismiss() }
                            }
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
    }
}
