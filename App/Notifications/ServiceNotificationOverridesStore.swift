import Foundation
import Observation
import RenderAPI

/// One service's override of the workspace's Render notification settings.
///
/// Each field is either `.workspaceDefault`, which follows `OwnerNotificationSettings`, or an
/// explicit value. Render answers `"default"` for a service that has never been overridden, and
/// setting both fields back to `"default"` removes the service from the override list, which is
/// the closest thing the API has to deleting an override.
struct ServiceNotificationOverrides: Equatable, Sendable {
    enum Level: Equatable, Hashable, Sendable {
        case workspaceDefault
        case level(OwnerNotificationSettings.Level)

        /// Render's string, as it appears in every override payload.
        init(raw: String) {
            self = OwnerNotificationSettings.Level(rawValue: raw).map(Level.level) ?? .workspaceDefault
        }

        var raw: String {
            switch self {
            case .workspaceDefault: "default"
            case .level(let level): level.rawValue
            }
        }

        static let allCases: [Level] = [.workspaceDefault] + OwnerNotificationSettings.Level.allCases.map(Level.level)
    }

    enum Preview: Equatable, Hashable, Sendable {
        case workspaceDefault
        case on
        case off

        init(raw: String) {
            switch raw {
            case "true": self = .on
            case "false": self = .off
            default: self = .workspaceDefault
            }
        }

        var raw: String {
            switch self {
            case .workspaceDefault: "default"
            case .on: "true"
            case .off: "false"
            }
        }

        static let allCases: [Preview] = [.workspaceDefault, .on, .off]
    }

    var notificationsToSend: Level
    var previewNotifications: Preview

    var isOverridden: Bool { notificationsToSend != .workspaceDefault || previewNotifications != .workspaceDefault }

    /// What actually applies to this service, given the workspace's settings.
    func effectiveLevel(workspace: OwnerNotificationSettings) -> OwnerNotificationSettings.Level {
        if case .level(let level) = notificationsToSend { return level }
        return workspace.notificationsToSend
    }

    func effectivePreview(workspace: OwnerNotificationSettings) -> Bool {
        switch previewNotifications {
        case .workspaceDefault: workspace.previewNotificationsEnabled
        case .on: true
        case .off: false
        }
    }
}

/// Loads and edits one service's notification overrides, alongside the workspace settings they
/// override so the screen can say what "workspace default" currently means.
///
/// Writes follow `NotificationSettingsStore`: optimistic, rolled back with Render's reason if the
/// PATCH fails, and replaced by the reply when it succeeds.
@MainActor
@Observable
final class ServiceNotificationOverridesStore {
    private(set) var overrides: ServiceNotificationOverrides?
    /// Optional for the screen: without it the defaults are just labelled "Workspace default".
    private(set) var workspace: OwnerNotificationSettings?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var errorMessage: String?

    private let client: RenderClient
    private let ownerID: String
    let serviceID: String
    /// Bumped by every write, so a read that started before one can't replace what it saved.
    private var writeGeneration = 0

    init(client: RenderClient, ownerID: String, serviceID: String) {
        self.client = client
        self.ownerID = ownerID
        self.serviceID = serviceID
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let client = client
        let ownerID = ownerID
        // A save in flight when this read starts, or one that starts while it's out, will answer
        // with the settings as they now are, so this read's answer, and its error, would be stale.
        let generationAtStart = writeGeneration
        let startedDuringSave = isSaving
        async let workspaceAttempt = try? client.api
            .retrieveOwnerNotificationSettings(path: .init(ownerId: ownerID))
            .ok.body.json

        let result: Result<ServiceNotificationOverrides, any Error>
        do {
            let payload = try await client.api
                .retrieveServiceNotificationOverrides(path: .init(serviceId: serviceID))
                .ok.body.json
            result = .success(ServiceNotificationOverrides(
                notificationsToSend: .init(raw: payload.notificationsToSend.rawValue),
                previewNotifications: .init(raw: payload.previewNotificationsEnabled.rawValue)
            ))
        } catch {
            result = .failure(error)
        }

        if !startedDuringSave, generationAtStart == writeGeneration {
            switch result {
            case .success(let loaded):
                overrides = loaded
                errorMessage = nil
            case .failure(let error):
                errorMessage = RenderError.wrapping(error).errorDescription
            }
        }

        if let payload = await workspaceAttempt {
            workspace = OwnerNotificationSettings(
                notificationsToSend: .init(rawValue: payload.notificationsToSend.rawValue) ?? .failure,
                emailEnabled: payload.emailEnabled,
                previewNotificationsEnabled: payload.previewNotificationsEnabled,
                slackEnabled: payload.slackEnabled
            )
        }
    }

    /// Applies an edit locally, sends only the field that changed, and puts the old value back if
    /// Render refuses.
    func update(_ transform: (inout ServiceNotificationOverrides) -> Void) async {
        guard var edited = overrides, !isSaving else { return }
        let previous = edited
        transform(&edited)
        guard edited != previous else { return }
        writeGeneration += 1
        overrides = edited

        isSaving = true
        defer { isSaving = false }
        do {
            let payload = try await client.api
                .patchServiceNotificationOverrides(
                    path: .init(serviceId: serviceID),
                    body: .json(.init(
                        previewNotificationsEnabled: edited.previewNotifications == previous.previewNotifications
                            ? nil : .init(rawValue: edited.previewNotifications.raw),
                        notificationsToSend: edited.notificationsToSend == previous.notificationsToSend
                            ? nil : .init(rawValue: edited.notificationsToSend.raw)
                    ))
                )
                .ok.body.json
            overrides = ServiceNotificationOverrides(
                notificationsToSend: .init(raw: payload.notificationsToSend.rawValue),
                previewNotifications: .init(raw: payload.previewNotificationsEnabled.rawValue)
            )
            errorMessage = nil
        } catch {
            overrides = previous
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// Puts both fields back to the workspace default, which removes the service from Render's
    /// override list.
    func resetToWorkspaceDefaults() async {
        await update {
            $0.notificationsToSend = .workspaceDefault
            $0.previewNotifications = .workspaceDefault
        }
    }
}
