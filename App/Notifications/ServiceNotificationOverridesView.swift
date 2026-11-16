import RenderAPI
import SwiftUI

/// Render's email and Slack notifications for one service: follow the workspace, or choose here.
///
/// Distinct from "Notify Me About Failures" on the service screen, which is this device's own
/// watchlist. These settings apply to everyone in the workspace, and the footer says so.
struct ServiceNotificationOverridesView: View {
    @State private var store: ServiceNotificationOverridesStore
    private let serviceName: String

    init(client: RenderClient, ownerID: String, serviceID: String, serviceName: String) {
        self.serviceName = serviceName
        _store = State(initialValue: ServiceNotificationOverridesStore(
            client: client, ownerID: ownerID, serviceID: serviceID
        ))
    }

    var body: some View {
        List {
            if let overrides = store.overrides {
                settingsSection(overrides)
                if overrides.isOverridden {
                    Section {
                        Button("Use Workspace Settings", systemImage: "arrow.uturn.backward") {
                            Task { await store.resetToWorkspaceDefaults() }
                        }
                        .disabled(store.isSaving)
                    }
                }
                if let message = store.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            } else if store.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("Render Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.load() }
        .refreshable { await store.load() }
    }

    private func settingsSection(_ overrides: ServiceNotificationOverrides) -> some View {
        Section {
            Picker("Send Notifications", selection: levelBinding(overrides)) {
                ForEach(ServiceNotificationOverrides.Level.allCases, id: \.self) { level in
                    Text(title(for: level)).tag(level)
                }
            }
            Picker("Preview Environments", selection: previewBinding(overrides)) {
                ForEach(ServiceNotificationOverrides.Preview.allCases, id: \.self) { preview in
                    Text(title(for: preview)).tag(preview)
                }
            }
        } header: {
            HStack {
                Text(serviceName)
                if store.isSaving {
                    Spacer()
                    ProgressView()
                }
            }
        } footer: {
            Text("Render sends these by email and Slack to everyone in the workspace. \"Workspace setting\" follows the workspace's Render notification settings. This device's alerts are set by Notify Me About Failures.")
        }
    }

    // MARK: - Titles

    /// "Workspace setting (Only failures)" when the workspace's value is known, so the default isn't
    /// a mystery.
    private func title(for level: ServiceNotificationOverrides.Level) -> String {
        switch level {
        case .workspaceDefault:
            store.workspace.map { "Workspace setting (\($0.notificationsToSend.displayName))" } ?? "Workspace setting"
        case .level(let level):
            level.displayName
        }
    }

    private func title(for preview: ServiceNotificationOverrides.Preview) -> String {
        switch preview {
        case .workspaceDefault:
            store.workspace.map { "Workspace setting (\($0.previewNotificationsEnabled ? "On" : "Off"))" } ?? "Workspace setting"
        case .on: "On"
        case .off: "Off"
        }
    }

    // MARK: - Bindings

    private func levelBinding(_ overrides: ServiceNotificationOverrides) -> Binding<ServiceNotificationOverrides.Level> {
        Binding(
            get: { overrides.notificationsToSend },
            set: { level in Task { await store.update { $0.notificationsToSend = level } } }
        )
    }

    private func previewBinding(_ overrides: ServiceNotificationOverrides) -> Binding<ServiceNotificationOverrides.Preview> {
        Binding(
            get: { overrides.previewNotifications },
            set: { preview in Task { await store.update { $0.previewNotifications = preview } } }
        )
    }
}
