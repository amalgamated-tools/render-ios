import SwiftUI

@main
struct RenderApp: App {
    /// The notification delegate has to exist before launch finishes, or a tap that *launched* the
    /// app has nowhere to be delivered and the deep link is lost.
    init() {
        FailureWatchCoordinator.shared.installNotificationDelegate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(FailureWatchCoordinator.shared)
                .environment(FailureWatchCoordinator.shared.router)
        }
        // Registers the handler; the request itself is submitted by the coordinator, which
        // re-submits at the start of every run so a thrown poll can't end the schedule.
        .backgroundTask(.appRefresh(FailureWatchCoordinator.taskIdentifier)) {
            await FailureWatchCoordinator.shared.handleBackgroundRefresh()
        }
    }
}
