import RenderAPI
import SwiftUI

/// Which env groups a service inherits configuration from — and a way to change that.
///
/// Reached from the service detail screen, which is where the question gets asked: the env vars screen
/// shows only what's set *directly*, so a service whose configuration all lives in a group looks empty
/// there. This is the other half of that answer.
struct ServiceEnvGroupsView: View {
    @State private var store: ServiceEnvGroupsStore
    @State private var isLinking = false
    @State private var pendingUnlink: EnvGroupSummary?

    private let client: RenderClient

    init(client: RenderClient, ownerID: String, service: ServiceDetailModel, deployer: ConfigDeployer?) {
        self.client = client
        _store = State(
            initialValue: ServiceEnvGroupsStore(
                client: client,
                ownerID: ownerID,
                serviceID: service.id,
                serviceName: service.name,
                deployer: deployer
            )
        )
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.groups.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            Section {
                if store.linkedGroups.isEmpty, !store.isLoading {
                    Text("This service inherits nothing from a group.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(store.linkedGroups) { group in
                    row(for: group)
                }
            } header: {
                Text("Linked Groups")
            } footer: {
                Text("Variables and files from these groups reach the service in addition to its own.")
            }

            if !store.availableGroups.isEmpty {
                Section {
                    Button("Link a Group", systemImage: "plus") { isLinking = true }
                        .disabled(store.writeInFlight != nil)
                }
            }
        }
        .navigationTitle("Env Groups")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .overlay { emptyOrErrorState }
        .safeAreaInset(edge: .bottom) { banner }
        .sheet(isPresented: $isLinking) {
            NavigationStack {
                List(store.availableGroups) { group in
                    Button {
                        Task { if await store.link(group) { isLinking = false } }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group.name)
                                .font(.subheadline)
                            Text(group.linkSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.writeInFlight != nil)
                }
                .navigationTitle("Link a Group")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isLinking = false }
                    }
                }
            }
        }
        .confirmationDialog(
            "Unlink \(pendingUnlink?.name ?? "")?",
            isPresented: .init(get: { pendingUnlink != nil }, set: { if !$0 { pendingUnlink = nil } }),
            titleVisibility: .visible,
            presenting: pendingUnlink
        ) { group in
            Button("Unlink", role: .destructive) {
                Task { await store.unlink(group) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The service keeps these variables until its next deploy, then loses them.")
        }
    }

    private func row(for group: EnvGroupSummary) -> some View {
        NavigationLink {
            // The group's own screen, without its link picker: linking from here would be linking
            // *other* services to the group, which isn't what this screen is about.
            EnvGroupDetailView(client: client, group: group)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.subheadline.weight(.semibold))
                    Text(group.linkSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.writeInFlight == group.id {
                    ProgressView()
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Unlink", systemImage: "link", role: .destructive) {
                pendingUnlink = group
            }
        }
        .disabled(store.writeInFlight != nil)
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.groups.isEmpty {
            if let message = store.errorMessage {
                ContentUnavailableView {
                    Label("Couldn't load environment groups", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await store.refresh() } }
                }
            } else if store.isLoading {
                ProgressView()
            } else {
                ContentUnavailableView {
                    Label("No Environment Groups", systemImage: "rectangle.stack")
                } description: {
                    Text("This workspace has no groups to link.")
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
