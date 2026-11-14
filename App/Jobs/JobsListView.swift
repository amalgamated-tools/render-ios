import RenderAPI
import SwiftUI

/// A service's one-off jobs, newest first, with Start in the toolbar and Cancel on a running row.
struct JobsListView: View {
    @State private var store: JobsStore
    @State private var isShowingStartSheet = false
    @State private var pendingCancel: JobSummary?

    private let serviceName: String
    /// Non-nil when Render is known to refuse a start here (the Free plan). Start is then disabled
    /// and the reason is shown, rather than offering a sheet whose only outcome is an error.
    private let startUnavailableReason: String?

    init(client: RenderClient, serviceID: String, serviceName: String, startUnavailableReason: String?) {
        _store = State(initialValue: JobsStore(client: client, serviceID: serviceID))
        self.serviceName = serviceName
        self.startUnavailableReason = startUnavailableReason
    }

    var body: some View {
        List {
            if let startUnavailableReason {
                Section {
                    Label(startUnavailableReason, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(store.jobs) { job in
                    NavigationLink {
                        JobDetailView(store: store, jobID: job.id, serviceName: serviceName)
                    } label: {
                        JobRow(job: job)
                    }
                    // Not a full swipe, for the same reason as deploy rollback: a long swipe would
                    // cancel without the confirmation ever showing.
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if job.isActive {
                            Button("Cancel Job", systemImage: "xmark.circle") { pendingCancel = job }
                                .tint(.red)
                        }
                    }
                }
                if store.hasMore && store.errorMessage == nil && !store.jobs.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowSeparator(.hidden)
                        .onAppear { Task { await store.loadNextPage() } }
                }
            }
        }
        .navigationTitle("Jobs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Start Job", systemImage: "plus") { isShowingStartSheet = true }
                    .disabled(startUnavailableReason != nil || store.writeInFlight != nil)
            }
        }
        .refreshable { await store.refresh() }
        .task { if store.jobs.isEmpty { await store.refresh() } }
        // No stopPolling in onDisappear: pushing a job's detail screen fires it, and that screen
        // relies on this store's polling. The poll loop holds the store weakly, so it ends when the
        // screen is popped and the store goes away.
        .overlay { emptyState }
        .safeAreaInset(edge: .bottom) { JobActionBanner(store: store) }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(isPresented: $isShowingStartSheet) {
            StartJobSheet(serviceName: serviceName) { command in
                Task { await store.start(command: command) }
            }
        }
        .jobCancelConfirmation(job: $pendingCancel, store: store)
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = store.errorMessage, store.jobs.isEmpty {
            ErrorStateView(subject: "jobs", message: message) { await store.refresh() }
        } else if store.jobs.isEmpty && store.isLoading {
            SkeletonList()
        } else if store.jobs.isEmpty {
            ContentUnavailableView(
                "No Jobs",
                systemImage: "terminal",
                description: Text("One-off jobs run a single command with this service's code and environment, then stop.")
            )
        }
    }
}

/// One job: status, the command, when it started and how long it ran.
struct JobRow: View {
    let job: JobSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            JobStatusChip(status: job.status, isCompact: true)
            Text(job.startCommand)
                .font(.subheadline.monospaced())
                .lineLimit(2)
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var metadata: String {
        var parts = [job.createdAt.formatted(.relative(presentation: .named))]
        if let duration = job.duration {
            parts.append(DeployRow.durationFormat(duration))
        }
        return parts.joined(separator: " · ")
    }
}

struct JobStatusChip: View {
    let status: JobSummary.Status?
    var isCompact = false

    var body: some View {
        StatusChip(
            title: status?.displayName ?? "Unknown",
            systemImage: systemImage,
            tint: tint,
            isCompact: isCompact,
            isActive: status?.isActive ?? false
        )
        .accessibilityLabel("Job status: \(status?.displayName ?? "Unknown")")
    }

    private var systemImage: String {
        switch status {
        case .pending: "clock"
        case .running: "terminal"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.octagon.fill"
        case .canceled: "slash.circle"
        case nil: "questionmark.circle"
        }
    }

    /// The same palette as deploys: blue in motion, orange waiting, green done, red needs a look.
    private var tint: Color {
        switch status {
        case .pending: .orange
        case .running: .blue
        case .succeeded: .green
        case .failed: .red
        case .canceled, nil: .secondary
        }
    }
}

/// The command entry. Starting is confirmed here rather than in a second dialog: typing a command
/// and tapping Start is already deliberate, the same as choosing an instance count in Scale.
private struct StartJobSheet: View {
    let serviceName: String
    let onStart: @MainActor (String) -> Void

    @State private var command = ""
    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Command", text: $command, prompt: Text("npm run migrate"), axis: .vertical)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isFocused)
                } footer: {
                    Text("Runs once on a new instance with \(serviceName)'s latest build, environment and instance type. It's billed like the service while it runs, and doesn't affect the running service.")
                }
            }
            .navigationTitle("Start Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        dismiss()
                        onStart(trimmed)
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { isFocused = true }
        }
    }
}

/// Outcome banner shared by the list and the detail screen, which both write through one store.
struct JobActionBanner: View {
    let store: JobsStore

    var body: some View {
        if let result = store.actionResult {
            HStack(spacing: 8) {
                Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(result.message).font(.subheadline)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { store.dismissActionResult() }
                    .labelStyle(.iconOnly)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .foregroundStyle(result.isFailure ? .red : .green)
            .padding(.horizontal)
        }
    }
}

extension View {
    /// Cancelling is confirmed: it stops someone's migration halfway through, and Render doesn't
    /// say what state that leaves the data in.
    func jobCancelConfirmation(job: Binding<JobSummary?>, store: JobsStore) -> some View {
        confirmationDialog(
            "Cancel this job?",
            isPresented: .init(get: { job.wrappedValue != nil }, set: { if !$0 { job.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: job.wrappedValue
        ) { pending in
            Button("Cancel Job", role: .destructive) {
                Task { await store.cancel(jobID: pending.id) }
            }
            Button("Keep Running", role: .cancel) {}
        } message: { pending in
            Text("Stops it wherever it's got to. Anything it already changed stays changed.\n\n\(pending.startCommand)")
        }
    }
}
