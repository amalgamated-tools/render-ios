import Foundation
import UserNotifications

/// Turns ``FailureAlert``s into notifications on the lock screen.
///
/// Thin on purpose: everything with a rule worth testing lives in ``FailureWatcher``, and
/// `UNUserNotificationCenter` is not something a unit test can stand in for.
@MainActor
final class NotificationScheduler {
    enum Authorization: Equatable {
        /// Never asked. The only state in which asking is allowed to show a system prompt.
        case notDetermined
        case authorized
        /// Declined, or switched off in Settings later. Asking again does nothing, so the UI has to
        /// say so and point at Settings instead.
        case denied
    }

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorization() async -> Authorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .authorized, .provisional, .ephemeral: .authorized
        default: .denied
        }
    }

    /// Asks for permission, once. Returns whether notifications can now be posted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func post(_ alerts: [FailureAlert]) async {
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.serviceName
            content.body = alert.summary
            content.sound = .default
            // Groups a service's alerts together, so a service failing repeatedly reads as one
            // situation rather than filling the lock screen.
            content.threadIdentifier = alert.serviceID
            content.userInfo = [
                NotificationRouter.serviceIDKey: alert.serviceID,
                // The tap may have to switch workspace before it can navigate, so the owner has to
                // survive the round trip through the notification.
                NotificationRouter.ownerIDKey: alert.ownerID,
            ]
            // Opens on the failure itself rather than the service — the "why" is the point of tapping.
            if let eventID = alert.eventID {
                content.userInfo[NotificationRouter.eventIDKey] = eventID
            }

            // A nil trigger delivers immediately, which is what a background wake wants — the
            // failure already happened.
            let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
            try? await center.add(request)
        }
    }
}
