import Foundation
import Observation
import UserNotifications

/// Where a tapped notification wants to go.
///
/// Held rather than acted on, because the destination may not exist yet: opening a service in
/// another workspace switches `selectedOwnerID` first, and `WorkspaceScreen` is `.id(ownerID)`-keyed,
/// so the screen that has to perform the navigation is rebuilt in the same turn. The target waits
/// here until a screen that can honour it says it has.
@MainActor
@Observable
final class NotificationRouter {
    // `nonisolated` because the delivery side reads them: `UNUserNotificationCenterDelegate`'s
    // methods aren't main-actor isolated, and hopping to the actor just to read a string constant
    // would be ceremony.
    nonisolated static let serviceIDKey = "serviceID"
    nonisolated static let ownerIDKey = "ownerID"
    nonisolated static let eventIDKey = "eventID"

    struct Target: Hashable, Sendable {
        let ownerID: String
        let serviceID: String
        let serviceName: String
        /// The event to open on top of the service. Absent on notifications posted before event
        /// detail existed, and on deploy alerts resolved from the deploy list.
        var eventID: String? = nil
    }

    private(set) var pending: Target?

    /// The service currently on screen, so a notification for it can be shown as a banner or not.
    /// Set by ``ServiceDetailView``.
    var foregroundServiceID: String?

    func request(_ target: Target) {
        pending = target
    }

    /// Called by whichever screen performed the navigation.
    func consume() {
        pending = nil
    }

    /// Builds a target from a notification's `userInfo`, or `nil` if it didn't come from this app's
    /// failure alerts.
    nonisolated static func target(from userInfo: [AnyHashable: Any], name: String) -> Target? {
        guard let serviceID = userInfo[serviceIDKey] as? String,
              let ownerID = userInfo[ownerIDKey] as? String
        else { return nil }
        return Target(
            ownerID: ownerID,
            serviceID: serviceID,
            serviceName: name,
            eventID: userInfo[eventIDKey] as? String
        )
    }
}

/// Receives taps and foreground deliveries.
///
/// A separate object from the router because `UNUserNotificationCenterDelegate` is an `NSObject`
/// protocol and the router is `@Observable`; making one type do both would drag `@Observable`'s
/// macro over an `NSObject` subclass for no gain.
///
/// **These are the completion-handler methods, not the `async` ones, deliberately.** The `async`
/// spellings are bridged by returning the value to an ObjC completion block from whatever executor
/// the continuation happens to resume on. UIKit runs state restoration and snapshotting off the back
/// of that block and asserts if it isn't the main thread — which crashed the app on every tapped
/// notification, at launch, with a stack that names UIKit rather than this file. Implementing the
/// completion-handler form and calling the handler synchronously keeps the reply on the thread
/// `UNUserNotificationCenter` delivered on, which is the main one.
///
/// **Which is observed behaviour, not a documented guarantee** — so both methods check rather than
/// assert. `MainActor.assumeIsolated` traps if it's ever wrong, and it would trap here, on the path
/// that runs when someone taps a failure alert. That is the last place in this app worth betting a
/// crash on an undocumented invariant, and the check costs a bool.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// `NotificationRouter` is main-actor isolated and therefore `Sendable`. This class is not: the
    /// protocol hands it non-`Sendable` `UNNotification` arguments from a nonisolated context.
    private let router: NotificationRouter

    init(router: NotificationRouter) {
        self.router = router
        super.init()
    }

    /// A notification that arrives while the user is already looking at that service is noise — they
    /// can see the failure. Anything else still deserves a banner.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let serviceID = notification.request.content.userInfo[NotificationRouter.serviceIDKey] as? String
        let router = self.router
        // The answer has to be synchronous — the completion handler takes the options — so off the
        // main thread there's nothing to read and the fallback is to present. Suppression is a
        // nicety; a swallowed failure alert is the thing this feature exists to prevent.
        let isOnScreen = Thread.isMainThread
            && MainActor.assumeIsolated { router.foregroundServiceID == serviceID }
        completionHandler(isOnScreen ? [] : [.banner, .sound, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let content = response.notification.request.content
        if let target = NotificationRouter.target(from: content.userInfo, name: content.title) {
            let router = self.router
            // Synchronously when we can, so a tap that launched the app has its destination set
            // before the first `WorkspaceScreen` reads it. Otherwise hop — the target is held, not
            // acted on, so arriving a turn late costs nothing but a rebuild.
            if Thread.isMainThread {
                MainActor.assumeIsolated { router.request(target) }
            } else {
                Task { @MainActor in router.request(target) }
            }
        }
        completionHandler()
    }
}
