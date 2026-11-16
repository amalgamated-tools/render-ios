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

    /// A service whose Render notifications differ from the workspace's.
    struct OverriddenService: Identifiable, Equatable, Sendable {
        let id: String
        /// `nil` when the service couldn't be read, such as one deleted since it was overridden.
        let name: String?
        let overrides: ServiceNotificationOverrides
    }

    /// Services with their own Render notification settings, sorted by name. `nil` until loaded.
    private(set) var overriddenServices: [OverriddenService]?
    private(set) var overridesErrorMessage: String?

    private let client: RenderClient
    private let ownerID: String

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
    }

    /// Loads `GET /notification-settings/overrides` for this workspace, then each service's name.
    /// The override list carries only service IDs, and the services list can't be filtered by ID.
    func loadOverrides() async {
        let client = client
        let ownerID = ownerID
        do {
            let paginator = CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listNotificationOverrides(query: .init(ownerId: [ownerID], cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { envelope in
                (
                    (
                        id: envelope.override.serviceId,
                        overrides: ServiceNotificationOverrides(
                            notificationsToSend: .init(raw: envelope.override.notificationsToSend.rawValue),
                            previewNotifications: .init(raw: envelope.override.previewNotificationsEnabled.rawValue)
                        )
                    ),
                    envelope.cursor
                )
            }
            // Render keeps a service listed only while one of its fields isn't "default".
            let listed = try await paginator.collect(limit: 200).filter(\.overrides.isOverridden)

            let names = await withTaskGroup(of: (String, String?).self) { group in
                for entry in listed {
                    group.addTask {
                        let name = try? await client.api
                            .retrieveService(path: .init(serviceId: entry.id))
                            .ok.body.json.name
                        return (entry.id, name)
                    }
                }
                var names: [String: String?] = [:]
                for await (id, name) in group { names[id] = name }
                return names
            }

            overriddenServices = listed
                .map { OverriddenService(id: $0.id, name: names[$0.id] ?? nil, overrides: $0.overrides) }
                .sorted { ($0.name ?? $0.id).localizedStandardCompare($1.name ?? $1.id) == .orderedAscending }
            overridesErrorMessage = nil
        } catch {
            overridesErrorMessage = RenderError.wrapping(error).errorDescription
        }
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
