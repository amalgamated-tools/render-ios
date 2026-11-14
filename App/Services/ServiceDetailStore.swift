import Foundation
import Observation
import RenderAPI

/// A service as the detail screen needs it: the list projection plus everything only
/// `GET /services/{id}` carries.
struct ServiceDetailModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: Components.Schemas.ServiceType
    let isSuspended: Bool
    let suspenders: [Components.Schemas.SuspenderType]
    let repo: String?
    let branch: String?
    let rootDir: String
    let imagePath: String?
    let isAutoDeployEnabled: Bool
    let environmentID: String?
    let dashboardURL: URL?
    let createdAt: Date
    let updatedAt: Date
    /// Type-driven read of the undiscriminated `serviceDetails` union. See `ServiceDetails+Decode`.
    let details: ServiceDetails

    init(_ service: Components.Schemas.Service) {
        self.id = service.id
        self.name = service.name
        self.type = service._type
        self.isSuspended = service.suspended == .suspended
        self.suspenders = service.suspenders
        self.repo = service.repo
        self.branch = service.branch
        self.rootDir = service.rootDir
        self.imagePath = service.imagePath
        self.isAutoDeployEnabled = service.autoDeploy == .yes
        self.environmentID = service.environmentId
        self.dashboardURL = URL(string: service.dashboardUrl)
        self.createdAt = service.createdAt
        self.updatedAt = service.updatedAt
        self.details = ServiceDetails(service)
    }
}

/// A cron run Render has started and not yet reported as ended.
struct ActiveCronRun: Hashable, Sendable {
    let id: String
    /// `nil` between triggering a run and Render recording that it started.
    let startedAt: Date?
}

/// The most recent cron run Render has reported as ended.
struct FinishedCronRun: Hashable, Sendable {
    let id: String
    let endedAt: Date
    /// `successful`, `unsuccessful` or `canceled`, as the `cron_job_run_ended` event reports it.
    let status: String?

    var statusTitle: String {
        switch status {
        case "successful": "Succeeded"
        case "unsuccessful": "Failed"
        case "canceled": "Canceled"
        default: "Ended"
        }
    }
}

/// Backs the service detail screen: the service itself, its current deploy, and the lifecycle
/// actions.
///
/// Every action follows the same path — call, show the outcome in a banner, then reload the service
/// and its latest deploy, because these endpoints are asynchronous and the local copy is stale the
/// moment they return. While a deploy is in progress the store polls until it settles, so a triggered
/// deploy visibly transitions without the user pulling to refresh.
@MainActor
@Observable
final class ServiceDetailStore {
    private(set) var service: ServiceDetailModel?
    private(set) var latestDeploy: DeploySummary?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Set when the deploy-history call failed while the service itself loaded — the header then says
    /// status is unavailable rather than implying the service has never deployed.
    private(set) var deployErrorMessage: String?
    /// Set while an action's request is in flight, to disable the menu and show which one is running.
    private(set) var actionInFlight: ServiceAction?
    /// Outcome banner for the last action — success or failure.
    private(set) var actionResult: ActionResult?
    /// The cron run in progress, for a cron job. See ``reloadCronRuns()`` for how it's worked out.
    private(set) var activeCronRun: ActiveCronRun?
    private(set) var lastCronRun: FinishedCronRun?
    /// The run a cancel was sent for. Render's 204 doesn't say whether anything stopped, so the run
    /// shows as canceling, without a second Cancel, until its end event arrives.
    private(set) var cancelRequestedRunID: String?

    var isCancelingCronRun: Bool {
        activeCronRun != nil && activeCronRun?.id == cancelRequestedRunID
    }

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private let client: RenderClient
    let serviceID: String
    /// Interval between polls while a deploy is in progress. A deploy takes minutes, so this is a
    /// compromise between looking live and burning the rate limit.
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?
    /// The run the trigger call returned, held until Render's events catch up with it.
    private var triggeredRun: (id: String, at: Date)?
    private let now: @Sendable () -> Date

    /// How long a triggered run counts as in progress with no event to back it. Render records the
    /// start within seconds; this only stops a run whose events never arrive from polling forever.
    static let triggeredRunGrace: TimeInterval = 5 * 60
    /// Older than this, a start with no end event is treated as a lost event rather than a run still
    /// going. A guard against polling forever, not a documented Render limit.
    static let startedRunLimit: TimeInterval = 24 * 60 * 60

    init(
        client: RenderClient,
        serviceID: String,
        pollInterval: Duration = .seconds(6),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.serviceID = serviceID
        self.pollInterval = pollInterval
        self.now = now
    }

    /// Actions offered for the current service, in menu order. Empty until the service loads, since
    /// availability depends on its type and suspended state.
    var availableActions: [ServiceAction] {
        guard let service else { return [] }
        var actions: [ServiceAction] = []

        if let deploy = latestDeploy, deploy.isInProgress {
            actions.append(.cancelDeploy(deployID: deploy.id))
        }
        if service.type == .cronJob {
            actions.append(.runCronJob)
            if activeCronRun != nil, !isCancelingCronRun {
                actions.append(.cancelCronRun)
            }
        } else {
            let source: ServiceAction.Source = service.details.runtime == .image ? .image : .commit
            actions.append(.deploy(clearCache: false, source: source))
            // An image-backed service has no build to cache, so offering a cache-clearing build is
            // offering something that can't happen.
            if source == .commit {
                actions.append(.deploy(clearCache: true, source: source))
            }
        }
        if service.type.supportsRestart {
            actions.append(.restart)
        }
        if service.type.supportsCachePurge {
            actions.append(.purgeCache)
        }
        actions.append(service.isSuspended ? .resume : .suspend)
        return actions
    }

    /// Loads the service and its latest deploy together, then resumes polling if mid-deploy.
    func load() async {
        isLoading = service == nil
        defer { isLoading = false }
        await reload()
        startPollingIfNeeded()
    }

    /// Pull-to-refresh: same fetch, but never shows the full-screen spinner.
    func refresh() async {
        await reload()
        startPollingIfNeeded()
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func dismissActionResult() {
        actionResult = nil
    }

    /// Runs an action, then reloads so the UI reflects what Render actually did.
    func perform(_ action: ServiceAction) async {
        guard actionInFlight == nil else { return }
        actionInFlight = action
        actionResult = nil
        defer { actionInFlight = nil }

        // Taken before the call: by the time it returns, a reload may have moved on to another run.
        let runToCancel = activeCronRun?.id
        do {
            try await send(action)
            if case .cancelCronRun = action {
                cancelRequestedRunID = runToCancel
            }
            actionResult = ActionResult(message: action.successMessage, isFailure: false)
        } catch {
            let message = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
            actionResult = ActionResult(message: message, isFailure: true)
        }
        // Reload either way: a failed action can still have changed state (e.g. a deploy that was
        // accepted and then errored on the response), and a stale screen is worse than a slow one.
        await reload()
        startPollingIfNeeded()
    }

    // MARK: - API calls

    /// The one place a `ServiceAction` becomes an API call. Each generated operation returns a
    /// distinct success case (200/201/202), and `StatusMappingMiddleware` has already turned any
    /// terminal 4xx/5xx into a thrown `RenderError` — so these only need to *reach* the success
    /// accessor, which throws if the response wasn't the documented one.
    private func send(_ action: ServiceAction) async throws {
        switch action {
        case .deploy(let clearCache, _):
            // Shared with the config screens' banner, which starts the same deploy.
            try await DeploysStore.createDeploy(
                client: client,
                serviceID: serviceID,
                clearCache: clearCache
            )
        case .rollback(let deployID):
            _ = try await client.api.rollbackDeploy(
                path: .init(serviceId: serviceID),
                body: .json(.init(deployId: deployID))
            ).created
        case .cancelDeploy(let deployID):
            _ = try await client.api.cancelDeploy(
                path: .init(serviceId: serviceID, deployId: deployID)
            ).ok
        case .restart:
            _ = try await client.api.restartService(path: .init(serviceId: serviceID)).ok
        case .suspend:
            _ = try await client.api.suspendService(path: .init(serviceId: serviceID)).accepted
        case .resume:
            _ = try await client.api.resumeService(path: .init(serviceId: serviceID)).accepted
        case .scale(let instances):
            _ = try await client.api.scaleService(
                path: .init(serviceId: serviceID),
                body: .json(.init(numInstances: instances))
            ).accepted
        case .purgeCache:
            _ = try await client.api.purgeCache(path: .init(serviceId: serviceID)).accepted
        case .runCronJob:
            // A cron job's service ID *is* its cron job ID; the endpoint just lives under /cron-jobs.
            let run = try await client.api.runCronJob(path: .init(cronJobId: serviceID)).ok.body.json
            triggeredRun = (run.id, now())
        case .cancelCronRun:
            // Cancels whatever run is in progress — the endpoint takes no run ID, and answers 204
            // even when nothing was running.
            _ = try await client.api.cancelCronJobRun(path: .init(cronJobId: serviceID)).noContent
        }
    }

    private func reload() async {
        let client = client
        let serviceID = serviceID
        // Independent calls, so overlap them — the detail screen shows both at once. The deploy leg
        // reports its own failure instead of throwing: losing deploy status shouldn't blank a screen
        // whose service loaded fine, and "never deployed" is a claim we can only make on a *reply*.
        async let deployAttempt: Result<DeploySummary?, any Error> = {
            do {
                return .success(try await DeploysStore.latestDeploy(client: client, serviceID: serviceID))
            } catch {
                return .failure(error)
            }
        }()

        do {
            let service = try await client.api
                .retrieveService(path: .init(serviceId: serviceID))
                .ok.body.json
            self.service = ServiceDetailModel(service)
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }

        switch await deployAttempt {
        case .success(let deploy):
            latestDeploy = deploy
            deployErrorMessage = nil
        case .failure(let error):
            latestDeploy = nil
            deployErrorMessage = RenderError.wrapping(error).errorDescription
        }

        if service?.type == .cronJob {
            await reloadCronRuns()
        }
    }

    /// Works out whether a cron run is in progress.
    ///
    /// The API has no list of runs, and cancelling answers 204 whether or not anything was running,
    /// so the only record is the event feed: a run is in progress when its `cron_job_run_started` has
    /// no matching `cron_job_run_ended`. Only the newest start matters — triggering a run cancels the
    /// one before it. Several recent ends are read, not one, because that cancelled run's end can land
    /// after the new run's start.
    ///
    /// A failure leaves the previous state alone: it's a side panel on the screen, and blanking a run
    /// that's still going would hide the way to cancel it.
    private func reloadCronRuns() async {
        let client = client
        let serviceID = serviceID
        // The spec says an omitted startTime means the last hour (the live API ignores that today).
        // Ask for the same day a start counts for, so a run over an hour long keeps its start. Ends
        // get no window: the last run's outcome should show however long ago it was.
        let startedSince = now().addingTimeInterval(-Self.startedRunLimit)
        async let startedAttempt = client.api.listEvents(
            path: .init(serviceId: serviceID),
            query: .init(_type: .cronJobRunStarted, startTime: startedSince, limit: 1)
        )
        async let endedAttempt = client.api.listEvents(
            path: .init(serviceId: serviceID),
            query: .init(_type: .cronJobRunEnded, limit: 5)
        )
        let startedResult = try? await startedAttempt.ok.body.json.map({ ServiceEvent($0.event) })
        let endedResult = try? await endedAttempt.ok.body.json.map({ ServiceEvent($0.event) })
        let now = now()
        let pendingTrigger = triggeredRun.flatMap {
            now.timeIntervalSince($0.at) < Self.triggeredRunGrace ? $0 : nil
        }

        guard let started = startedResult, let ended = endedResult else {
            // A run we just triggered is known to exist even though its events couldn't be read, so
            // show it (which also keeps polling) rather than leave the screen on the old state.
            if let pendingTrigger, activeCronRun?.id != pendingTrigger.id {
                activeCronRun = ActiveCronRun(id: pendingTrigger.id, startedAt: nil)
            }
            return
        }

        let endedIDs = Set(ended.compactMap(\.details.cronRunID))
        lastCronRun = ended.first.flatMap { event in
            event.details.cronRunID.map {
                FinishedCronRun(id: $0, endedAt: event.timestamp, status: event.details.runStatus)
            }
        }

        let newestStart = started.first.flatMap { event in
            event.details.cronRunID.map { (id: $0, at: event.timestamp) }
        }
        // A triggered run whose start Render hasn't recorded yet wins over an older unmatched start:
        // triggering cancels the run before it, so that older run is on its way out.
        if let pendingTrigger, !endedIDs.contains(pendingTrigger.id),
           newestStart?.id != pendingTrigger.id {
            activeCronRun = ActiveCronRun(id: pendingTrigger.id, startedAt: nil)
        } else if let start = newestStart, !endedIDs.contains(start.id),
                  now.timeIntervalSince(start.at) < Self.startedRunLimit {
            activeCronRun = ActiveCronRun(id: start.id, startedAt: start.at)
            if triggeredRun?.id == start.id { triggeredRun = nil }
        } else {
            activeCronRun = nil
            triggeredRun = nil
        }
    }

    private var needsPolling: Bool {
        latestDeploy?.isInProgress == true || activeCronRun != nil
    }

    /// Polls while the newest deploy or a cron run is still moving, and stops as soon as both settle —
    /// so an idle service costs no requests at all.
    private func startPollingIfNeeded() {
        guard needsPolling else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }

        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.reload()
                if !self.needsPolling {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
