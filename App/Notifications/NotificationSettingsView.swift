import RenderAPI
import SwiftUI

/// Everything about being told something, in one place: what this device watches, and what Render
/// itself sends to email and Slack.
///
/// The two halves are genuinely different mechanisms and are labelled as such. Render's settings
/// apply to the whole workspace and everyone in it; the watchlist applies to this phone only. Merging
/// them into one list of switches would make it look like turning one off turns the other off.
struct NotificationSettingsView: View {
    @State private var store: NotificationSettingsStore
    @State private var authorization: NotificationScheduler.Authorization = .notDetermined
    @Environment(FailureWatchCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private let ownerID: String

    init(client: RenderClient, ownerID: String) {
        self.ownerID = ownerID
        _store = State(initialValue: NotificationSettingsStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        NavigationStack {
            List {
                deviceSection
                renderSection
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                authorization = await coordinator.authorization()
                await store.load()
            }
        }
    }

    // MARK: - This device

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if authorization == .denied {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications are turned off")
                            Text("Watched services won't tell you anything until you turn them on in Settings.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "bell.slash.fill").foregroundStyle(.orange)
                    }
                }
            }

            let watched = coordinator.watchlist.watched(ownedBy: ownerID)
            if watched.isEmpty {
                Text("Not watching anything in this workspace. Open a service and turn on **Notify Me About Failures**.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(watched) { service in
                    Text(service.name)
                        .swipeActions {
                            Button("Stop Watching", systemImage: "bell.slash", role: .destructive) {
                                coordinator.unwatch(serviceID: service.id)
                            }
                        }
                }
            }
        } header: {
            Text("Watched On This Device")
        } footer: {
            // Said here as well as on the service screen, because this is the screen someone opens
            // when they're wondering why they weren't told.
            Text("This device checks watched services when you open the app and periodically in the background. iOS decides how often background checks run and never runs them while the app is force-quit, so treat this as a heads-up rather than a pager. Up to \(WatchlistStore.limit) services.")
        }
    }

    // MARK: - Render's own channels

    @ViewBuilder
    private var renderSection: some View {
        Section {
            if let settings = store.settings {
                Picker("Send Notifications", selection: notificationLevel(settings)) {
                    ForEach(OwnerNotificationSettings.Level.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                Toggle("Email", isOn: emailEnabled(settings))
                Toggle("Preview Environments", isOn: previewEnabled(settings))
                LabeledContent("Slack", value: settings.slackEnabled ? "Connected" : "Not connected")
            } else if store.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let message = store.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        } header: {
            HStack {
                Text("Render Notifications")
                if store.isSaving {
                    Spacer()
                    ProgressView()
                }
            }
        } footer: {
            Text("These apply to everyone in this workspace, not just this device. Slack is connected from the Render dashboard.")
        }
    }

    // MARK: - Bindings

    private func notificationLevel(_ settings: OwnerNotificationSettings) -> Binding<OwnerNotificationSettings.Level> {
        Binding(
            get: { settings.notificationsToSend },
            set: { level in Task { await store.update { $0.notificationsToSend = level } } }
        )
    }

    private func emailEnabled(_ settings: OwnerNotificationSettings) -> Binding<Bool> {
        Binding(
            get: { settings.emailEnabled },
            set: { isOn in Task { await store.update { $0.emailEnabled = isOn } } }
        )
    }

    private func previewEnabled(_ settings: OwnerNotificationSettings) -> Binding<Bool> {
        Binding(
            get: { settings.previewNotificationsEnabled },
            set: { isOn in Task { await store.update { $0.previewNotificationsEnabled = isOn } } }
        )
    }
}
