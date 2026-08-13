import RenderAPI
import SwiftUI

/// One env group: rename it, edit what's in it, and control which services get it.
///
/// The two config sections are the *same screens* a service's own configuration uses — same masking,
/// same editors, same key-at-a-time writes — handed a different backend. What differs is only what the
/// messages can honestly promise: a group's change waits on every linked service's next deploy, so
/// there's no Deploy button here. See ``ConfigScope``.
struct EnvGroupDetailView: View {
    @State private var store: EnvGroupDetailStore
    @State private var isRenaming = false
    @State private var isLinking = false
    @State private var pendingUnlink: EnvGroupServiceLink?

    private let client: RenderClient
    private let ownerID: String?

    /// - Parameters:
    ///   - ownerID: The workspace to pick services from when linking. `nil` hides the link affordance,
    ///     which is what the service-side entry point wants — it links from the other direction.
    ///   - onChange: Handed the updated group so the list behind this screen stays current.
    init(
        client: RenderClient,
        group: EnvGroupSummary,
        ownerID: String? = nil,
        onChange: @escaping (EnvGroupSummary) -> Void = { _ in }
    ) {
        self.client = client
        self.ownerID = ownerID
        _store = State(
            initialValue: EnvGroupDetailStore(client: client, group: group, onChange: onChange)
        )
    }

    var body: some View {
        List {
            configurationSection
            linkedServicesSection
        }
        .navigationTitle(store.group.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        // Re-read on return from the variables screen, so the header and link count reflect writes
        // made there.
        .task { await store.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Rename", systemImage: "pencil") { isRenaming = true }
                    .disabled(store.writeInFlight != nil)
            }
        }
        .safeAreaInset(edge: .bottom) { banner }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(isPresented: $isRenaming) {
            EnvGroupRenameSheet(store: store)
        }
        .sheet(isPresented: $isLinking) {
            if let ownerID {
                EnvGroupLinkPicker(client: client, ownerID: ownerID, store: store)
            }
        }
        .confirmationDialog(
            "Unlink \(pendingUnlink?.name ?? "")?",
            isPresented: .init(get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }),
            titleVisibility: .visible,
            presenting: pendingUnlink
        ) { link in
            Button("Unlink", role: .destructive) {
                Task { await store.unlink(link) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { link in
            Text("\(link.name) keeps these variables until its next deploy, then loses them.")
        }
    }

    private var configurationSection: some View {
        Section {
            NavigationLink {
                EnvVarsView(backend: store.envVarBackend)
            } label: {
                Label("Environment Variables", systemImage: "key")
            }
            NavigationLink {
                SecretFilesView(backend: store.secretFileBackend)
            } label: {
                Label("Secret Files", systemImage: "doc.text")
            }
        } footer: {
            // One sentence, not two half-repeating ones: lower-casing `linkSummary` and appending it
            // produced "Shared by every linked service. no linked services." on the live pass.
            Text(sharingFooter)
        }
    }

    /// Who this group's contents reach. Worth being exact about, because it's what makes editing them
    /// consequential — or, at zero, harmless.
    private var sharingFooter: String {
        switch store.group.linkedServiceCount {
        case 0: "Nothing is linked yet, so these reach no services."
        case 1: "Shared by the 1 linked service below."
        default: "Shared by all \(store.group.linkedServiceCount) linked services below."
        }
    }

    @ViewBuilder
    private var linkedServicesSection: some View {
        Section {
            if store.group.links.isEmpty {
                Text("No services are linked to this group yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(store.sortedLinks) { link in
                HStack(spacing: 10) {
                    Image(systemName: link.type.systemImage)
                        .foregroundStyle(link.type.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(link.name)
                            .font(.subheadline)
                        Text(link.type.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if store.writeInFlight == link.id {
                        ProgressView()
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Unlink", systemImage: "link.badge.plus", role: .destructive) {
                        pendingUnlink = link
                    }
                }
                .disabled(store.writeInFlight != nil)
            }
            if ownerID != nil {
                Button("Link a Service", systemImage: "plus") { isLinking = true }
                    .disabled(store.writeInFlight != nil)
            }
        } header: {
            Text("Linked Services")
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let result = store.actionResult {
            ConfigResultBanner(
                result: result,
                deployer: nil,
                deploy: {},
                dismiss: { store.dismissActionResult() }
            )
        }
    }
}

/// Renames a group.
///
/// Unlike an env var key or a secret file name, a group's name really can be changed: Render addresses
/// the group by ID, so this is a `PATCH` and not a delete-plus-create.
struct EnvGroupRenameSheet: View {
    let store: EnvGroupDetailStore

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    private var canSave: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != store.group.name && store.writeInFlight == nil
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
                    // Worth saying, because every other rename in this app is impossible.
                    Text("Renaming a group changes nothing the linked services read, so it needs no deploy.")
                }
            }
            .navigationTitle("Rename Group")
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
                            Task { if await store.rename(to: name) { dismiss() } }
                        }
                        .disabled(!canSave)
                    }
                }
            }
            .onAppear { name = store.group.name }
        }
    }
}

/// Picks a service to link to the group.
///
/// Reuses ``ServicesStore`` rather than re-listing services: search, paging, and PR-preview exclusion
/// are all decisions already made once for the service list, and a picker that disagreed with the list
/// about which services exist would be its own bug.
struct EnvGroupLinkPicker: View {
    @State private var services: ServicesStore
    let store: EnvGroupDetailStore

    @Environment(\.dismiss) private var dismiss

    init(client: RenderClient, ownerID: String, store: EnvGroupDetailStore) {
        _services = State(initialValue: ServicesStore(client: client, ownerID: ownerID))
        self.store = store
    }

    /// Already-linked services are filtered out rather than shown disabled: the list answers "what can
    /// I add", and a re-link is a request with nothing to do.
    private var candidates: [ServiceSummary] {
        let linked = Set(store.group.links.map(\.id))
        return services.visibleServices.filter { !linked.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(candidates) { service in
                    Button {
                        Task {
                            if await store.link(serviceID: service.id, serviceName: service.name) {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: service.type.systemImage)
                                .foregroundStyle(service.type.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(service.name)
                                    .font(.subheadline)
                                Text(service.type.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.writeInFlight != nil)
                }
                if services.hasMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .task { await services.loadNextPage() }
                }
            }
            .navigationTitle("Link a Service")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $services.searchText, prompt: "Search services")
            .task { await services.refresh() }
            .overlay {
                if candidates.isEmpty, !services.isLoading {
                    ContentUnavailableView {
                        Label("Nothing to Link", systemImage: "link")
                    } description: {
                        Text("Every service in this workspace is already linked to this group.")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
