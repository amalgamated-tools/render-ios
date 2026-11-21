import RenderAPI
import SwiftUI

/// A service's persistent disk: its size and mount path, and the snapshots Render has taken of it.
struct DiskView: View {
    let disk: ServiceDetails.Disk
    @State private var store: DiskStore

    init(client: RenderClient, disk: ServiceDetails.Disk) {
        self.disk = disk
        _store = State(initialValue: DiskStore(client: client, diskID: disk.id))
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Name", value: disk.name)
                LabeledContent("Size", value: "\(disk.sizeGB) GB")
                LabeledContent("Mount Path") {
                    Text(disk.mountPath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            snapshotsSection
        }
        .navigationTitle("Disk")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
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
            }
            if store.hasLoaded, store.snapshots.isEmpty {
                Text("No snapshots yet.")
                    .foregroundStyle(.secondary)
            } else if !store.hasLoaded, store.error == nil, store.isLoading {
                ProgressView()
            }
        } header: {
            Text(store.snapshots.isEmpty ? "Snapshots" : "Snapshots (\(store.snapshots.count))")
        }
    }
}
