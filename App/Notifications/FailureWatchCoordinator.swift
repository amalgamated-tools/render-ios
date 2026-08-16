import BackgroundTasks
import Foundation
import Observation
import RenderAPI
import UserNotifications

/// Owns failure watching for the whole app: the watchlist, the watermarks, the background schedule,
/// and the delivery of alerts.
///
/// **Why a singleton**, when everything else in this app is injected. The `.backgroundTask` scene
/// modifier's handler is handed no view state, and on a cold background launch there may be no
/// `RootView` — and therefore no `AuthStore` — in existence when it runs. Something has to be
/// reachable from a static context and own state across launches. The parts with rules worth testing
/// (``FailureWatcher``, ``EventWatermark``) are ordinary injected types; this is the wiring around
/// them.
@MainActor
@Observable
final class FailureWatchCoordinator {
    static let shared = FailureWatchCoordinator()

    /// Must match `BGTaskSchedulerPermittedIdentifiers` in `Resources/Info.plist`; `submit` throws
    /// if it doesn't.
    static let taskIdentifier = "com.veverkap.RenderiOS.refresh"

    /// The floor iOS enforces on app refresh is 15 minutes, and asking for sooner doesn't move it.
    /// This is the earliest the system will *consider* running us, not a promise.
    static let refreshInterval: TimeInterval = 15 * 60

    /// How stale the last poll has to be before returning to the foreground triggers another. Low
    /// enough that reopening the app after a while checks, high enough that flicking between apps
    /// doesn't spend a request per switch.
    static let foregroundStaleness: TimeInterval = 60

    /// How long a background wake gets before it gives up on its own.
    ///
    /// iOS allows a `BGAppRefreshTask` roughly 30 seconds and then calls the expiration handler;
    /// stop short of that deliberately. Expiration is a few seconds' notice before the watchdog
    /// kills the app — and a termination doesn't just lose this run, it makes iOS schedule the next
    /// ones less generously, so the feature decays with no symptom but silence. Stopping early
    /// leaves room to post whatever the poll already found.
    ///
    /// Only the background path is bounded. A foreground poll is spending the user's own time on a
    /// screen they're looking at, and has no budget to blow.
    static let backgroundBudget: Duration = .seconds(20)

    let watchlist: WatchlistStore
    let watermarks: EventWatermarkStore
    let router = NotificationRouter()

    private let scheduler: NotificationScheduler
    private let makeClient: @MainActor () -> RenderClient
    private var delegate: NotificationDelegate?
    private var lastRun: Date?
    private var runTask: Task<Void, Never>?

    init(
        watchlist: WatchlistStore = WatchlistStore(),
        watermarks: EventWatermarkStore = EventWatermarkStore(),
        scheduler: NotificationScheduler = NotificationScheduler(),
        makeClient: @escaping @MainActor () -> RenderClient = { SharedCredentials.shared.client() }
    ) {
        self.watchlist = watchlist
        self.watermarks = watermarks
        self.scheduler = scheduler
        self.makeClient = makeClient
    }

    // MARK: - Lifecycle

    /// Installs the notification delegate. Called from `RenderApp.init` rather than from a view, so
    /// that a tap which *launched* the app has a delegate to be delivered to.
    func installNotificationDelegate() {
        let delegate = NotificationDelegate(router: router)
        self.delegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
    }

    /// Asks iOS to wake us again. Submitting is cheap and idempotent — a pending request for the
    /// same identifier is replaced, not duplicated.
    func scheduleNextRefresh() {
        guard !watchlist.watched.isEmpty else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)
        // Throws on a simulator without the identifier registered, and when too many requests are
        // pending. Neither is worth failing a launch over, and neither is actionable by the user.
        try? BGTaskScheduler.shared.submit(request)
    }

    /// The background entry point.
    ///
    /// Re-schedules **before** polling, deliberately. Scheduling last means any early return — no
    /// credential, no permission, a thrown call — leaves nothing pending, and the feature stops
    /// working permanently with no symptom other than silence.
    ///
    /// Bounded by ``backgroundBudget``, and cancellable throughout: SwiftUI cancels this task when
    /// iOS expires the wake, and that has to actually reach the requests in flight.
    func handleBackgroundRefresh() async {
        scheduleNextRefresh()
        await Self.withDeadline(Self.backgroundBudget) { await self.run() }
    }

    /// Runs `body`, cancelling it if it hasn't finished within `duration`.
    ///
    /// A task group rather than a detached race, so the deadline also inherits cancellation from
    /// *above* — an expiration that arrives before the budget runs out still stops the work.
    private static func withDeadline(
        _ duration: Duration,
        _ body: @escaping @Sendable () async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await body() }
            group.addTask { try? await Task.sleep(for: duration) }
            // Whichever lands first wins; cancelling the group stops the other.
            await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
    }

    /// The foreground entry point, on returning to the app.
    ///
    /// Background refresh is unreliable enough — iOS decides, and never runs a force-quit app — that
    /// this is what makes the feature feel alive. Throttled so app switching doesn't poll.
    func runIfStale() async {
        if let lastRun, Date().timeIntervalSince(lastRun) < Self.foregroundStaleness { return }
        await run()
    }

    /// Checks every watched service and posts what it finds.
    ///
    /// The run itself is unstructured — it has to outlive whichever caller started it, so that the
    /// second caller can join rather than duplicate it. Unstructured means it does *not* inherit
    /// cancellation, which on the background path would leave a cancelled wake with requests still
    /// in flight and no way for iOS's expiration to reach them; hence the explicit handler. Callers
    /// that merely joined cancel nothing: they didn't start the work and don't get to end it.
    func run() async {
        // Coalesce: a foreground return that lands while a background wake is still polling would
        // otherwise double every request and race on the watermarks.
        if let runTask {
            await runTask.value
            return
        }
        let task = Task { await self.performRun() }
        runTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        runTask = nil
    }

    private func performRun() async {
        guard !watchlist.watched.isEmpty else { return }
        // Cheap preconditions first: both are local, and either one failing means every request
        // below would be wasted.
        guard SharedCredentials.shared.hasStoredCredential else { return }
        guard await scheduler.authorization() == .authorized else { return }

        // Stamped here rather than on entry, so the throttle only ever holds back a *poll*. A run
        // that bailed because there was no credential yet spent nothing, and shouldn't buy itself a
        // minute of silence during which the credential arrives and nobody looks.
        lastRun = Date()
        let watcher = FailureWatcher(
            client: makeClient(),
            watchlist: watchlist,
            watermarks: watermarks
        )
        // A cut-short poll returns what it had already confirmed, and leaves the watermarks of the
        // services it never reached where they were — so the next wake re-examines those windows.
        let alerts = await watcher.poll()
        guard !alerts.isEmpty else { return }
        // Shielded from cancellation on purpose. These failures are already established fact, and
        // posting them is local work measured in milliseconds; dropping them at the finish line
        // because the wake ran out of time would waste the requests that found them. An
        // unstructured task doesn't inherit cancellation, which is the whole point here.
        await Task { @MainActor in await self.scheduler.post(alerts) }.value
    }

    // MARK: - Watchlist

    /// What came of asking to watch a service.
    ///
    /// A tri-state rather than a `Bool`, because "added, but iOS will deliver nothing" is neither a
    /// success nor a failure and is invisible unless it's said out loud. Every entry point has to
    /// report the same three outcomes in the same words, which is why the copy lives here and not in
    /// whichever view happened to ask.
    enum WatchOutcome: Equatable {
        case watching
        /// On the list, but notifications are off for the app — so nothing will ever arrive.
        case notificationsDenied
        case watchlistFull

        var title: String? {
            switch self {
            case .watching: nil
            case .notificationsDenied: "Notifications Are Off"
            case .watchlistFull: "Watchlist Full"
            }
        }

        var message: String? {
            switch self {
            case .watching:
                nil
            case .notificationsDenied:
                "This service is on the list, but notifications are turned off for this app. "
                    + "Turn them on in Settings to be told about failures."
            case .watchlistFull:
                "You can watch up to \(WatchlistStore.limit) services. Stop watching one to add another."
            }
        }
    }

    /// Starts watching a service, requesting notification permission the first time — which is why
    /// this is here rather than on the store: the permission prompt belongs to the moment the user
    /// asks to be told something, not to app launch.
    @discardableResult
    func watch(serviceID: String, ownerID: String, name: String) async -> WatchOutcome {
        guard watchlist.add(id: serviceID, ownerID: ownerID, name: name) else { return .watchlistFull }
        watermarks.begin(serviceID: serviceID, at: Date())
        if await scheduler.authorization() == .notDetermined {
            await scheduler.requestAuthorization()
        }
        scheduleNextRefresh()
        // Asked and refused, or switched off in Settings since. Watching without permission goes
        // through every motion and delivers nothing, which is the worst outcome an alerting feature
        // has — worse than refusing to add it, because it looks like it worked.
        return await scheduler.authorization() == .denied ? .notificationsDenied : .watching
    }

    func unwatch(serviceID: String) {
        watchlist.remove(id: serviceID)
        watermarks.forget(serviceID: serviceID)
        if watchlist.watched.isEmpty {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        }
    }

    func authorization() async -> NotificationScheduler.Authorization {
        await scheduler.authorization()
    }

    /// Clears everything this device remembers about watching. Called on sign-out: a watchlist that
    /// outlived its credential would poll with no session, and a watermark that outlived it would
    /// suppress the first real alert after signing back in.
    func reset() {
        watchlist.removeAll()
        watermarks.prune(keeping: [])
        lastRun = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
