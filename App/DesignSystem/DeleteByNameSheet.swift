import SwiftUI

/// Confirms a delete by having the user type the exact name, so it can't happen from a stray tap.
/// Closes either way once Render has answered; a failure shows on the screen underneath.
struct DeleteByNameSheet: View {
    let title: String
    let name: String
    let explanation: String
    let delete: () async -> Bool

    @State private var typed = ""
    @State private var isWorking = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(name, text: $typed)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("deleteConfirmName")
                } header: {
                    Text("Type \(name) to confirm")
                } footer: {
                    Text(explanation)
                }
                Section {
                    Button(title, role: .destructive) {
                        isWorking = true
                        Task {
                            _ = await delete()
                            dismiss()
                        }
                    }
                    .disabled(typed != name || isWorking)
                    .accessibilityIdentifier("deleteConfirmButton")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isWorking)
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
    }
}
