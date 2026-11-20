import RenderAPI
import SwiftUI

/// The organization's audit log, read with its own Audit Log API key. Asks for the organization ID
/// and key the first time, since Render offers no way to look either up.
struct OrganizationAuditLogView: View {
    @State private var settings: OrgAuditLogSettings
    @State private var isChanging = false
    @State private var isConfirmingRemoval = false
    @State private var removalFailed = false

    init(settings: OrgAuditLogSettings = OrgAuditLogSettings()) {
        _settings = State(initialValue: settings)
    }

    var body: some View {
        Group {
            if let credential = settings.credential, !isChanging, let store = settings.makeLogStore() {
                AuditLogView(store: store, title: "Organization Audit Log",
                             emptyDescription: "Nothing has been recorded for \(credential.organizationID) recently.")
                    // A new organization or key needs a fresh store, not the old one's entries.
                    .id(credential)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu("Options", systemImage: "ellipsis.circle") {
                                Text(credential.organizationID)
                                Button("Change Organization or Key", systemImage: "key") { isChanging = true }
                                Button("Remove Key from This Device", systemImage: "trash", role: .destructive) {
                                    isConfirmingRemoval = true
                                }
                            }
                        }
                    }
                    .confirmationDialog("Remove the Audit Log API key?", isPresented: $isConfirmingRemoval,
                                        titleVisibility: .visible) {
                        Button("Remove Key", role: .destructive) { removalFailed = !settings.remove() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("It's deleted from this device only. The key still works until it's revoked in the Render Dashboard.")
                    }
                    .alert("Couldn't Remove the Key", isPresented: $removalFailed) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(settings.errorMessage ?? "The key is still saved on this device.")
                    }
            } else {
                OrgAuditLogSetupForm(
                    settings: settings,
                    initialOrganizationID: settings.credential?.organizationID ?? "",
                    onDone: { isChanging = false },
                    onCancel: settings.credential == nil ? nil : {
                        settings.cancelSave()
                        isChanging = false
                    }
                )
            }
        }
    }
}

/// Asks for the organization ID and Audit Log API key, and saves them once Render accepts them.
private struct OrgAuditLogSetupForm: View {
    let settings: OrgAuditLogSettings
    let onDone: () -> Void
    let onCancel: (() -> Void)?
    @State private var organizationID: String
    @State private var apiKey = ""

    init(settings: OrgAuditLogSettings, initialOrganizationID: String, onDone: @escaping () -> Void, onCancel: (() -> Void)?) {
        self.settings = settings
        self.onDone = onDone
        self.onCancel = onCancel
        _organizationID = State(initialValue: initialOrganizationID)
    }

    var body: some View {
        Form {
            Section {
                TextField("org-…", text: $organizationID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            } header: {
                Text("Organization ID")
            } footer: {
                Text("Render doesn't offer a way to look this up. It's in your organization's settings in the Render Dashboard.")
            }
            Section {
                // A plain field, not a `SecureField`: iOS reads a secure field next to the ID as a
                // login and offers to save the key to Passwords (seen live; see EnvVarsView). The
                // key is visible only on this form; once saved, the app never shows it again.
                TextField("Audit Log API key", text: $apiKey)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
            } header: {
                Text("Audit Log API Key")
            } footer: {
                Text("Your sign-in key can't read the organization's audit log. An organization admin creates a read-only Audit Log API key in the organization's settings. It's stored in this device's Keychain, apart from your sign-in, and stays when you sign out.")
            }
            if let message = settings.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                Button {
                    Task {
                        if await settings.save(organizationID: organizationID, apiKey: apiKey) { onDone() }
                    }
                } label: {
                    HStack {
                        Text("Save")
                        if settings.isVerifying {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(settings.isVerifying || organizationID.isEmpty || apiKey.isEmpty)
            }
        }
        .navigationTitle("Organization Audit Log")
        .navigationBarTitleDisplayMode(.inline)
        // Leaving the form any way, Back included, abandons a check still in flight. After a
        // successful save this runs too, with nothing left to drop.
        .onDisappear { settings.cancelSave() }
        // When changing a saved pair, Cancel returns to the list. Back would leave the whole
        // screen instead, and showing both side by side was confusing (seen live).
        .navigationBarBackButtonHidden(onCancel != nil)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}
