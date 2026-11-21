import RenderAPI
import SwiftUI

/// A service's persistent disk: its size and mount path, the snapshots Render has taken of it, and
/// growing the disk or restoring a snapshot, each confirmed first.
struct DiskView: View {
    let disk: ServiceDetails.Disk
    @State private var store: DiskStore
    @State private var isShowingResize = false
    @State private var confirmingRestore: DiskStore.Snapshot?

    init(client: RenderClient, disk: ServiceDetails.Disk) {
        self.disk = disk
        _store = State(initialValue: DiskStore(client: client, diskID: disk.id, sizeGB: disk.sizeGB))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: disk.name)
                LabeledContent("Size", value: "\(store.sizeGB) GB")
                LabeledContent("Mount Path") {
                    Text(disk.mountPath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("Resize…", systemImage: "arrow.up.left.and.arrow.down.right") {
                    isShowingResize = true
                }
                .disabled(store.isWriting)
                if store.isResizing {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Resizing…").foregroundStyle(.secondary)
                    }
                }
            }
            snapshotsSection
        }
        .navigationTitle("Disk")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
        .safeAreaInset(edge: .bottom) { actionBanner }
        .actionOutcomeFeedback(store.actionResult)
        .sheet(isPresented: $isShowingResize) {
            ResizeSheet(diskName: disk.name, store: store) { newSize in
                isShowingResize = false
                Task { await store.resize(to: newSize) }
            }
        }
        .confirmationDialog(
            restoreTitle,
            isPresented: Binding(
                get: { confirmingRestore != nil },
                set: { if !$0 { confirmingRestore = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirmingRestore
        ) { snapshot in
            Button("Restore and Overwrite", role: .destructive) {
                Task { await store.restore(snapshot) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Everything written to \(disk.name) since then is lost, and this can't be undone. Render may redeploy the service.")
        }
    }

    private var restoreTitle: String {
        guard let date = confirmingRestore?.createdAt else { return "Restore \(disk.name) from this snapshot?" }
        return "Restore \(disk.name) to \(date.formatted(date: .abbreviated, time: .shortened))?"
    }

    @ViewBuilder
    private var snapshotsSection: some View {
        Section {
            if let message = store.error {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            ForEach(store.snapshots) { snapshot in
                snapshotRow(snapshot)
            }
            if store.hasLoaded, store.snapshots.isEmpty {
                Text("No snapshots yet.")
                    .foregroundStyle(.secondary)
            } else if !store.hasLoaded, store.error == nil, store.isLoading {
                ProgressView()
            }
        } header: {
            Text(store.snapshots.isEmpty ? "Snapshots" : "Snapshots (\(store.snapshots.count))")
        } footer: {
            if !store.snapshots.isEmpty {
                Text("Restoring a snapshot replaces everything on the disk.")
            }
        }
    }

    private func snapshotRow(_ snapshot: DiskStore.Snapshot) -> some View {
        HStack {
            if let date = snapshot.createdAt {
                VStack(alignment: .leading, spacing: 2) {
                    Text(date, format: .dateTime.month().day().year().hour().minute())
                    Text(date, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Unknown date")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.restoringID == snapshot.id {
                ProgressView()
            } else {
                Button("Restore") { confirmingRestore = snapshot }
                    .buttonStyle(.borderless)
                    .disabled(store.isWriting)
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
}

/// Chooses a larger size. Asks for confirmation first, because a disk can't be shrunk again.
private struct ResizeSheet: View {
    let diskName: String
    let store: DiskStore
    let onSubmit: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isConfirming = false

    private var newSize: Int? { Int(text.trimmingCharacters(in: .whitespaces)) }
    private var validationMessage: String? { store.resizeValidationMessage(newSize) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Current Size", value: "\(store.sizeGB) GB")
                    LabeledContent("New Size") {
                        HStack(spacing: 4) {
                            TextField("\(store.sizeGB + 1)", text: $text)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                            Text("GB").foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    if !text.isEmpty, let validationMessage {
                        Text(validationMessage).foregroundStyle(.red)
                    } else {
                        Text("A disk can only grow. Render bills disks by size, and the service must be running for the change to take effect.")
                    }
                }
            }
            .navigationTitle("Resize Disk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Resize") { isConfirming = true }
                        .disabled(validationMessage != nil)
                }
            }
            .confirmationDialog(
                "Grow \(diskName) to \(newSize ?? 0) GB?",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Resize") { if let newSize { onSubmit(newSize) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can't make it smaller again.")
            }
        }
        .presentationDetents([.medium, .large])
    }
}
