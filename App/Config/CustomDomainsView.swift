import RenderAPI
import SwiftUI

/// A service's custom domains: what's serving, what isn't yet, and why.
///
/// The screen is built around the one question worth asking from a phone — *is this domain verified?* —
/// so unverified domains sort to the top and carry the DNS record that has to exist before they can be.
struct CustomDomainsView: View {
    @State private var store: CustomDomainsStore
    @State private var isAdding = false
    @State private var pendingDeletion: CustomDomainEntry?

    init(client: RenderClient, serviceID: String) {
        _store = State(initialValue: CustomDomainsStore(client: client, serviceID: serviceID))
    }

    var body: some View {
        List {
            if let message = store.errorMessage, !store.domains.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(store.sortedDomains) { domain in
                row(for: domain)
            }
        }
        .navigationTitle("Custom Domains")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Domain", systemImage: "plus") { isAdding = true }
                    .disabled(store.writeInFlight != nil)
            }
        }
        .overlay { emptyOrErrorState }
        .safeAreaInset(edge: .bottom) { banner }
        .sheet(isPresented: $isAdding) {
            CustomDomainAddSheet(store: store)
        }
        .confirmationDialog(
            "Remove \(pendingDeletion?.name ?? "")?",
            isPresented: .init(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { domain in
            Button("Remove", role: .destructive) {
                Task { await store.delete(domain) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            // No deploy stands between this and the internet, unlike every other config change here.
            Text("Traffic to this domain stops immediately. This doesn't wait for a deploy.")
        }
    }

    private func row(for domain: CustomDomainEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(domain.name)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if store.writeInFlight == domain.id {
                    ProgressView()
                } else {
                    statusChip(for: domain)
                }
            }

            HStack(spacing: 6) {
                Text(domain.domainType == .apex ? "Apex" : "Subdomain")
                if domain.isRedirect {
                    // Render creates this row itself alongside an apex; without saying so it reads as
                    // a domain the user didn't ask for.
                    Text("· redirects to \(domain.redirectForName)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !domain.isVerified {
                Text(domain.dnsInstruction)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Check DNS Now", systemImage: "arrow.clockwise") {
                    Task { await store.verify(domain) }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(store.writeInFlight != nil)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Remove", systemImage: "trash", role: .destructive) {
                pendingDeletion = domain
            }
        }
    }

    private func statusChip(for domain: CustomDomainEntry) -> some View {
        Text(domain.isVerified ? "Verified" : "Unverified")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                (domain.isVerified ? Color.green : Color.orange).opacity(0.15),
                in: Capsule()
            )
            .foregroundStyle(domain.isVerified ? .green : .orange)
    }

    @ViewBuilder
    private var emptyOrErrorState: some View {
        if store.domains.isEmpty {
            if let message = store.errorMessage {
                ErrorStateView(subject: "custom domains", message: message) { await store.refresh() }
            } else if store.isLoading {
                SkeletonList()
            } else {
                ContentUnavailableView {
                    Label("No Custom Domains", systemImage: "globe")
                } description: {
                    Text("The service is reachable at its onrender.com address until you add one.")
                }
            }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if let result = store.actionResult {
            // No deployer: a domain change takes effect without one, so offering a build here would
            // imply the opposite.
            ConfigResultBanner(
                result: result,
                deployer: nil,
                deploy: {},
                dismiss: { store.dismissActionResult() }
            )
        }
    }
}

/// Adds a domain.
struct CustomDomainAddSheet: View {
    let store: CustomDomainsStore

    @State private var name = ""
    @Environment(\.dismiss) private var dismiss

    /// A hostname, not a URL. Pasting from a browser is the obvious mistake, so it's named rather than
    /// silently stripped — quietly rewriting what someone typed is how the wrong domain gets added.
    private var nameProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") { return "Enter just the hostname, without https://." }
        if trimmed.contains("/") { return "Enter just the hostname, without a path." }
        if !trimmed.contains(".") { return "A domain needs at least one dot." }
        if store.containsName(trimmed) { return "\(trimmed) is already on this service." }
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
                    TextField("api.example.com", text: $name)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("Domain")
                } footer: {
                    Text("Adding an apex domain also adds a www redirect for it. Render issues the certificate once DNS resolves.")
                }

                if let problem = nameProblem {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            .navigationTitle("Add Domain")
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
                            Task { if await store.add(name: name) { dismiss() } }
                        }
                        .disabled(!canSave)
                    }
                }
            }
        }
    }
}
