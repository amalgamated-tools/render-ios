import Foundation
import Observation
import RenderAPI

/// A Postgres instance as the detail screen needs it: the list projection plus everything only
/// `GET /postgres/{id}` carries.
struct PostgresDetailModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: Components.Schemas.DatabaseStatus
    let isSuspended: Bool
    let suspenders: [Components.Schemas.SuspenderType]
    let role: Components.Schemas.DatabaseRole
    let isHighAvailabilityEnabled: Bool
    let planDisplayName: String
    let region: Components.Schemas.Region
    let version: String
    let diskSizeGB: Int?
    let isDiskAutoscalingEnabled: Bool
    let databaseName: String
    let databaseUser: String
    let primaryPostgresID: String?
    let readReplicaNames: [String]
    let ipAllowListCount: Int
    let maintenanceScheduledAt: Date?
    let environmentID: String?
    let dashboardURL: URL?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?

    init(_ detail: Components.Schemas.PostgresDetail) {
        self.id = detail.id
        self.name = detail.name
        self.status = detail.status
        self.isSuspended = detail.suspended == .suspended
        self.suspenders = detail.suspenders
        self.role = detail.role
        self.isHighAvailabilityEnabled = detail.highAvailabilityEnabled
        self.planDisplayName = datastorePlanDisplayName(detail.plan.rawValue)
        self.region = detail.region
        self.version = detail.version.rawValue
        self.diskSizeGB = detail.diskSizeGB
        self.isDiskAutoscalingEnabled = detail.diskAutoscalingEnabled
        self.databaseName = detail.databaseName
        self.databaseUser = detail.databaseUser
        self.primaryPostgresID = detail.primaryPostgresID
        self.readReplicaNames = detail.readReplicas.map(\.name)
        self.ipAllowListCount = detail.ipAllowList.count
        self.maintenanceScheduledAt = detail.maintenance?.scheduledAt
        self.environmentID = detail.environmentId
        self.dashboardURL = URL(string: detail.dashboardUrl)
        self.createdAt = detail.createdAt
        self.updatedAt = detail.updatedAt
        self.expiresAt = detail.expiresAt
    }
}

/// Connection credentials from `GET /postgres/{id}/connection-info`. Every field is a secret.
struct PostgresConnectionModel: Hashable, Sendable {
    let password: String
    let internalConnectionString: String
    let externalConnectionString: String
    let internalConnectionPoolString: String?
    let externalConnectionPoolString: String?
    let psqlCommand: String

    init(_ info: Components.Schemas.PostgresConnectionInfo) {
        self.password = info.password
        self.internalConnectionString = info.internalConnectionString
        self.externalConnectionString = info.externalConnectionString
        self.internalConnectionPoolString = info.internalConnectionPoolString
        self.externalConnectionPoolString = info.externalConnectionPoolString
        self.psqlCommand = info.psqlCommand
    }
}

/// Backs the Postgres detail screen: the database itself, its connection info, and the lifecycle
/// actions.
///
/// Every action follows the `ServiceDetailStore` path — call, show the outcome in a banner, then
/// reload, because these endpoints are asynchronous and the local copy is stale the moment they
/// return. While the status is transitional the store polls until it settles.
@MainActor
@Observable
final class PostgresDetailStore {
    private(set) var database: PostgresDetailModel?
    private(set) var connection: PostgresConnectionModel?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Set when the connection-info call failed while the database itself loaded — the connection
    /// section then says so rather than blanking the whole screen.
    private(set) var connectionErrorMessage: String?
    /// Set while an action's request is in flight, to disable the menu and show which one is running.
    private(set) var actionInFlight: PostgresAction?
    /// Outcome banner for the last action — success or failure.
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private let client: RenderClient
    let postgresID: String
    /// Interval between polls while the status is transitional — a restart or failover takes a
    /// while, so this is a compromise between looking live and burning the rate limit.
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(client: RenderClient, postgresID: String, pollInterval: Duration = .seconds(6)) {
        self.client = client
        self.postgresID = postgresID
        self.pollInterval = pollInterval
    }

    /// Actions offered for the current database, in menu order. Empty until the detail loads,
    /// since availability depends on role, HA, and suspended state.
    var availableActions: [PostgresAction] {
        guard let database else { return [] }
        var actions: [PostgresAction] = []
        if !database.isSuspended {
            actions.append(.restart)
        }
        // Failover promotes the standby, so it needs one to exist (HA on), a primary to promote
        // *from*, and a database that is actually serving.
        if database.isHighAvailabilityEnabled, database.role == .primary, database.status == .available {
            actions.append(.failover)
        }
        actions.append(database.isSuspended ? .resume : .suspend)
        return actions
    }

    /// Loads the database and its connection info together, then resumes polling if mid-transition.
    func load() async {
        isLoading = database == nil
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
    func perform(_ action: PostgresAction) async {
        guard actionInFlight == nil else { return }
        actionInFlight = action
        actionResult = nil
        defer { actionInFlight = nil }

        do {
            try await send(action)
            actionResult = ActionResult(message: action.successMessage, isFailure: false)
        } catch {
            let message = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
            actionResult = ActionResult(message: message, isFailure: true)
        }
        await reload()
        startPollingIfNeeded()
    }

    // MARK: - API calls

    /// The one place a `PostgresAction` becomes an API call. All four endpoints answer 202;
    /// `StatusMappingMiddleware` has already turned any terminal 4xx/5xx into a thrown
    /// `RenderError`, so reaching `.accepted` is the whole check.
    private func send(_ action: PostgresAction) async throws {
        switch action {
        case .restart:
            _ = try await client.api.restartPostgres(path: .init(postgresId: postgresID)).accepted
        case .failover:
            _ = try await client.api.failoverPostgres(path: .init(postgresId: postgresID)).accepted
        case .suspend:
            _ = try await client.api.suspendPostgres(path: .init(postgresId: postgresID)).accepted
        case .resume:
            _ = try await client.api.resumePostgres(path: .init(postgresId: postgresID)).accepted
        }
    }

    private func reload() async {
        let client = client
        let postgresID = postgresID
        // Independent calls, so overlap them. The connection leg reports its own failure instead
        // of throwing: losing credentials display shouldn't blank a screen whose database loaded.
        async let connectionAttempt: Result<PostgresConnectionModel, any Error> = {
            do {
                let info = try await client.api
                    .retrievePostgresConnectionInfo(path: .init(postgresId: postgresID))
                    .ok.body.json
                return .success(PostgresConnectionModel(info))
            } catch {
                return .failure(error)
            }
        }()

        do {
            let detail = try await client.api
                .retrievePostgres(path: .init(postgresId: postgresID))
                .ok.body.json
            self.database = PostgresDetailModel(detail)
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }

        switch await connectionAttempt {
        case .success(let connection):
            self.connection = connection
            connectionErrorMessage = nil
        case .failure(let error):
            connection = nil
            connectionErrorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// Polls while the status is still moving, and stops as soon as it settles — so an idle
    /// database costs no requests at all.
    private func startPollingIfNeeded() {
        guard database?.status.isTransitional == true else {
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
                if self.database?.status.isTransitional != true {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
