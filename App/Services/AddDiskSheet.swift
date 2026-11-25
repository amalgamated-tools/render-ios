import RenderAPI
import SwiftUI

/// Adds a persistent disk to a service. Render attaches it on the next deploy, which the footer says,
/// since nothing on the service changes until then.
struct AddDiskSheet: View {
    let onCreated: (String) -> Void
    @State private var store: NewDiskStore
    @Environment(\.dismiss) private var dismiss

    init(client: RenderClient, serviceID: String, onCreated: @escaping (String) -> Void) {
        self.onCreated = onCreated
        _store = State(initialValue: NewDiskStore(client: client, serviceID: serviceID))
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $store.name)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("diskName")
                    LabeledContent("Size") {
                        HStack(spacing: 4) {
                            TextField("1", text: $store.sizeText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .accessibilityIdentifier("diskSize")
                            Text("GB").foregroundStyle(.secondary)
                        }
                    }
                    TextField("Mount Path, e.g. /var/data", text: $store.mountPath)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityIdentifier("diskMountPath")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let error = store.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                        Text("The disk attaches on the service's next deploy. Render bills disks by size, a disk can grow but never shrink, and a service with a disk can't run more than one instance or deploy without downtime.")
                    }
                }
            }
            .navigationTitle("Add Disk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(store.isCreating)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if store.isCreating {
                        ProgressView()
                    } else {
                        Button("Add") {
                            Task {
                                guard let name = await store.create() else { return }
                                onCreated(name)
                                dismiss()
                            }
                        }
                        .disabled(store.validationMessage != nil)
                        .accessibilityIdentifier("addDiskConfirm")
                    }
                }
            }
            .interactiveDismissDisabled(store.isCreating)
        }
        .presentationDetents([.medium, .large])
    }
}
