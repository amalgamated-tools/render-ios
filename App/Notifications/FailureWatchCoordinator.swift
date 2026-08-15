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
    func handleBackgroundRefresh() async {
        scheduleNextRefresh()
        await run()
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
    func run() async {
        // Coalesce: a foreground return that lands while a background wake is still polling would
        // otherwise double every request and race on the watermarks.
        if let runTask {
            await runTask.value
            return
        }
        let task = Task { await self.performRun() }
        runTask = task
        await task.value
        runTask = nil
    }

    private func performRun() async {
        lastRun = Date()
        guard !watchlist.watched.isEmpty else { return }
        // Cheap preconditions first: both are local, and either one failing means every request
        // below would be wasted.
        guard SharedCredentials.shared.hasStoredCredential else { return }
        guard await scheduler.authorization() == .authorized else { return }

        let watcher = FailureWatcher(
            client: makeClient(),
            watchlist: watchlist,
            watermarks: watermarks
        )
        let alerts = await watcher.poll()
        guard !alerts.isEmpty else { return }
        await scheduler.post(alerts)
    }

    // MARK: - Watchlist

    /// Starts watching a service, requesting notification permission the first time — which is why
    /// this is here rather than on the store: the permission prompt belongs to the moment the user
    /// asks to be told something, not to app launch.
    ///
    /// - Returns: `false` if the watchlist is full.
    @discardableResult
    func watch(serviceID: String, ownerID: String, name: String) async -> Bool {
        guard watchlist.add(id: serviceID, ownerID: ownerID, name: name) else { return false }
        watermarks.begin(serviceID: serviceID, at: Date())
        if await scheduler.authorization() == .notDetermined {
            await scheduler.requestAuthorization()
        }
        scheduleNextRefresh()
        return true
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
