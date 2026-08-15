import Foundation
import Observation
import RenderAPI

/// Render's own notification settings for a workspace — the email and Slack channels that exist
/// whether or not this app is installed.
///
/// Domain projection over three *different* generated payloads (the GET's response, the PATCH's
/// body, the PATCH's response) that describe the same five fields. Mapping through `rawValue` is
/// deliberate: the enums are structurally identical and generated separately, so a `switch` would be
/// three switches saying the same thing.
struct OwnerNotificationSettings: Equatable, Sendable {
    enum Level: String, CaseIterable, Identifiable, Sendable {
        case none, failure, all
        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: "Never"
            case .failure: "Only failures"
            case .all: "Every event"
            }
        }
    }

    var notificationsToSend: Level
    var emailEnabled: Bool
    var previewNotificationsEnabled: Bool
    /// Read-only: the API returns it but won't accept it in a PATCH, because connecting Slack is an
    /// OAuth dance that happens in the dashboard.
    let slackEnabled: Bool
}

/// Loads and edits one workspace's Render-side notification settings.
///
/// Writes are optimistic. Every control here is a toggle or a picker, and a control that waits for a
/// round trip before moving reads as broken; a control that moves and then snaps back with a reason
/// reads as a failed write, which is what it is.
@MainActor
@Observable
final class NotificationSettingsStore {
    private(set) var settings: OwnerNotificationSettings?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let client: RenderClient
    private let ownerID: String

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let payload = try await client.api
                .retrieveOwnerNotificationSettings(path: .init(ownerId: ownerID))
                .ok.body.json
            settings = OwnerNotificationSettings(
                notificationsToSend: .init(rawValue: payload.notificationsToSend.rawValue) ?? .failure,
                emailEnabled: payload.emailEnabled,
                previewNotificationsEnabled: payload.previewNotificationsEnabled,
                slackEnabled: payload.slackEnabled
            )
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// Applies an edit locally, sends it, and puts the old value back if Render refuses.
    func update(_ transform: (inout OwnerNotificationSettings) -> Void) async {
        guard var edited = settings else { return }
        let previous = edited
        transform(&edited)
        guard edited != previous else { return }
        settings = edited

        isSaving = true
        defer { isSaving = false }
        do {
            let payload = try await client.api
                .patchOwnerNotificationSettings(
                    path: .init(ownerId: ownerID),
                    body: .json(.init(
                        emailEnabled: edited.emailEnabled,
                        previewNotificationsEnabled: edited.previewNotificationsEnabled,
                        notificationsToSend: .init(rawValue: edited.notificationsToSend.rawValue)
                    ))
                )
                .ok.body.json
            // Trust the reply over the optimistic guess — Render is entitled to normalize.
            settings = OwnerNotificationSettings(
                notificationsToSend: .init(rawValue: payload.notificationsToSend.rawValue) ?? edited.notificationsToSend,
                emailEnabled: payload.emailEnabled,
                previewNotificationsEnabled: payload.previewNotificationsEnabled,
                slackEnabled: payload.slackEnabled
            )
            errorMessage = nil
        } catch {
            settings = previous
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }
}
