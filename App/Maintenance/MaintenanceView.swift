import RenderAPI
import SwiftUI

/// The workspace's maintenance runs, pushed from the workspace screen.
struct MaintenanceView: View {
    @State private var store: MaintenanceStore
    @State private var rescheduling: MaintenanceRun?
    @State private var confirmingTrigger: MaintenanceRun?

    init(client: RenderClient, ownerID: String) {
        _store = State(initialValue: MaintenanceStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        List {
            if store.hasLoaded {
                if let message = store.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                if store.runs.isEmpty, store.errorMessage == nil {
                    ContentUnavailableView(
                        "No Maintenance",
                        systemImage: "wrench.and.screwdriver",
                        description: Text("Render lists maintenance here when it schedules some for this workspace's services and datastores.")
                    )
                }
                if !store.upcoming.isEmpty {
                    Section("Upcoming") {
                        ForEach(store.upcoming) { run in row(run) }
                    }
                }
                if !store.finished.isEmpty {
                    Section("Past") {
                        ForEach(store.finished) { run in row(run) }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Maintenance")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
        .safeAreaInset(edge: .bottom) { MaintenanceActionBanner(store: store) }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(item: $rescheduling) { run in
            MaintenanceRescheduleSheet(run: run) { date in
                // The banner is under the sheet, so the sheet shows a failure itself.
                await store.reschedule(run, to: date) ? nil : (store.actionResult?.message ?? "Couldn't reschedule.")
            }
        }
        .confirmationDialog(
            "Run maintenance now?",
            isPresented: Binding(get: { confirmingTrigger != nil }, set: { if !$0 { confirmingTrigger = nil } }),
            titleVisibility: .visible,
            presenting: confirmingTrigger
        ) { run in
            Button("Run Now") { Task { await store.trigger(run) } }
            Button("Cancel", role: .cancel) {}
        } message: { run in
            Text("\(run.displayName) may be unavailable while maintenance runs.")
        }
    }

    private func row(_ run: MaintenanceRun) -> some View {
        MaintenanceRow(run: run)
            .swipeActions(edge: .trailing) {
                if run.state.isActionable {
                    Button("Run Now", systemImage: "play.fill") { confirmingTrigger = run }
                        .tint(.orange)
                    Button("Reschedule", systemImage: "calendar") { rescheduling = run }
                        .tint(.blue)
                }
            }
            .contextMenu {
                if run.state.isActionable {
                    Button("Reschedule", systemImage: "calendar") { rescheduling = run }
                    Button("Run Now", systemImage: "play.fill") { confirmingTrigger = run }
                }
            }
            .disabled(store.isSaving)
    }
}

struct MaintenanceRow: View {
    let run: MaintenanceRun

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(run.displayName).font(.headline)
                Spacer()
                Text(run.state.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
            }
            Text(run.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if run.state.isActionable, let latest = run.pendingMaintenanceBy {
                Text("Must run by \(latest.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        switch run.state {
        case .scheduled: .blue
        case .inProgress: .orange
        case .userFixRequired, .failed: .red
        case .succeeded: .green
        case .cancelled, .other: .secondary
        }
    }
}

struct MaintenanceRescheduleSheet: View {
    let run: MaintenanceRun
    /// Returns nil on success, or why it failed.
    let save: (Date) async -> String?
    @State private var date: Date
    @State private var isSaving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(run: MaintenanceRun, save: @escaping (Date) async -> String?) {
        self.run = run
        self.save = save
        _date = State(initialValue: run.scheduledAt)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("Start", selection: $date, in: range, displayedComponents: [.date, .hourAndMinute])
                } footer: {
                    if let latest = run.pendingMaintenanceBy {
                        Text("Render requires this maintenance to start before \(latest.formatted(date: .abbreviated, time: .shortened)).")
                    }
                }
                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(run.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        isSaving = true
                        failure = nil
                        Task {
                            if let message = await save(date) {
                                failure = message
                            } else {
                                dismiss()
                            }
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || date == run.scheduledAt)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var range: ClosedRange<Date> {
        let now = Date()
        // The deadline itself isn't allowed, and the picker works in whole minutes.
        let latest = max((run.pendingMaintenanceBy ?? .distantFuture).addingTimeInterval(-60), now)
        return now...latest
    }
}

struct MaintenanceActionBanner: View {
    let store: MaintenanceStore

    var body: some View {
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
