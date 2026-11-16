import RenderAPI
import SwiftUI

/// Point-in-time recovery and logical exports for one Postgres database.
struct PostgresBackupsView: View {
    @State private var store: PostgresBackupsStore
    @State private var isShowingRestoreSheet = false

    private let client: RenderClient
    private let ownerID: String
    private let databaseName: String

    init(client: RenderClient, ownerID: String, postgresID: String, databaseName: String) {
        self.client = client
        self.ownerID = ownerID
        self.databaseName = databaseName
        _store = State(initialValue: PostgresBackupsStore(client: client, postgresID: postgresID))
    }

    var body: some View {
        List {
            if store.hasLoaded {
                recoverySection
                if let restored = store.restoredDatabase {
                    restoredSection(restored)
                }
                exportsSection
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Backups")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.load() }
        .onDisappear { store.stopPolling() }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(isPresented: $isShowingRestoreSheet) {
            if let window = store.recoveryWindow {
                RestoreSheet(databaseName: databaseName, window: window) { request in
                    isShowingRestoreSheet = false
                    Task { await store.restore(request) }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var recoverySection: some View {
        Section {
            if let recovery = store.recovery {
                switch recovery.status {
                case .available:
                    if let startsAt = recovery.startsAt {
                        LabeledContent("Restore From", value: startsAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    Button("Restore to a Point in Time…", systemImage: "clock.arrow.circlepath") {
                        isShowingRestoreSheet = true
                    }
                    .disabled(store.isRestoring || store.recoveryWindow == nil)
                case .backupNotReady:
                    Label("Render is taking the first backup. You can restore once it finishes.", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                case .notAvailable:
                    Label("Point-in-time recovery isn't available for this database.", systemImage: "nosign")
                        .foregroundStyle(.secondary)
                }
            } else if store.recoveryErrorMessage != nil {
                Label("Recovery info unavailable", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if store.isRestoring {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Starting restore…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Point-in-Time Recovery")
        } footer: {
            Text("A restore creates a new database with this one's data from the time you choose. \(databaseName) isn't changed.")
        }
    }

    private func restoredSection(_ restored: PostgresDetailModel) -> some View {
        Section("Restored Database") {
            NavigationLink {
                PostgresDetailView(client: client, ownerID: ownerID, postgresID: restored.id, databaseName: restored.name)
            } label: {
                HStack {
                    Text(restored.name)
                        .lineLimit(1)
                    Spacer()
                    DatabaseStatusChip(status: restored.status, isCompact: true)
                }
            }
        }
    }

    @ViewBuilder
    private var exportsSection: some View {
        Section {
            Button("Create Export", systemImage: "square.and.arrow.down.on.square") {
                Task { await store.requestExport() }
            }
            .disabled(store.isRequestingExport || store.isWatchingForExport)

            if store.isWatchingForExport {
                Label("Waiting for the export to finish…", systemImage: "dot.radiowaves.left.and.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if let message = store.exportsErrorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if store.exports.isEmpty {
                Text("No exports yet.").foregroundStyle(.secondary)
            }
            ForEach(store.exports) { export in
                exportRow(export)
            }
        } header: {
            Text("Exports")
        } footer: {
            Text("An export is a full logical backup you can download.")
        }
    }

    @ViewBuilder
    private func exportRow(_ export: PostgresExport) -> some View {
        let created = export.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let url = export.url {
            Link(destination: url) {
                LabeledContent(created) {
                    Image(systemName: "arrow.down.circle")
                }
            }
        } else {
            LabeledContent(created, value: "Preparing")
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

/// Chooses a name and a time for a point-in-time restore. Restore asks for confirmation first,
/// because it creates a new billed database.
private struct RestoreSheet: View {
    let databaseName: String
    let window: ClosedRange<Date>
    let onSubmit: (PostgresRestoreRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var request: PostgresRestoreRequest
    @State private var isConfirming = false

    init(databaseName: String, window: ClosedRange<Date>, onSubmit: @escaping (PostgresRestoreRequest) -> Void) {
        self.databaseName = databaseName
        self.window = window
        self.onSubmit = onSubmit
        _request = State(initialValue: PostgresRestoreRequest(name: "\(databaseName)-restore", time: window.upperBound))
    }

    /// Checked against a window that ends now, not when the sheet opened, so waiting on the sheet
    /// never makes a valid time look invalid.
    private var validationMessage: String? {
        request.validationMessage(window: window.lowerBound...max(window.upperBound, Date()))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $request.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("New Database Name")
                }
                Section {
                    DatePicker("Restore To", selection: $request.time, in: window)
                } footer: {
                    Text("From \(window.lowerBound.formatted(date: .abbreviated, time: .shortened)) up to Render's latest backup point, which can trail the current time. If the time is too recent, Render says how far back you can go.")
                }
                Section {
                    if let validationMessage {
                        Text(validationMessage).foregroundStyle(.red)
                    }
                } footer: {
                    Text("Render creates a new database on the same plan as \(databaseName), and bills it separately. \(databaseName) isn't changed.")
                }
            }
            .navigationTitle("Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restore") { isConfirming = true }
                        .disabled(validationMessage != nil)
                }
            }
            .confirmationDialog(
                "Create \(request.trimmedName) from \(databaseName)?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Restore") { onSubmit(request) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Creates a new database with \(databaseName)'s data as of \(request.time.formatted(date: .abbreviated, time: .standard)). \(databaseName) isn't changed.")
            }
        }
    }
}
