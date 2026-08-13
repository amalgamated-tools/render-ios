import Foundation
import Observation
import RenderAPI

/// A Key Value instance as the detail screen needs it: the list projection plus everything only
/// `GET /key-value/{id}` carries. No `dashboardURL` — the detail schema doesn't have one, so the
/// detail *view* carries the list row's copy instead.
struct KeyValueDetailModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let status: Components.Schemas.DatabaseStatus
    let planDisplayName: String
    let region: Components.Schemas.Region
    let version: String
    let maxmemoryPolicy: String?
    let persistenceMode: Components.Schemas.PersistenceMode?
    let ipAllowListCount: Int
    let maintenanceScheduledAt: Date?
    let environmentID: String?
    let createdAt: Date
    let updatedAt: Date

    /// The schema has no `suspended` field; the status is the only signal.
    var isSuspended: Bool { status == .suspended }

    init(_ detail: Components.Schemas.KeyValueDetail) {
        self.id = detail.id
        self.name = detail.name
        self.status = detail.status
        self.planDisplayName = datastorePlanDisplayName(detail.plan.rawValue)
        self.region = detail.region
        self.version = detail.version
        self.maxmemoryPolicy = detail.options.maxmemoryPolicy
        self.persistenceMode = detail.options.persistenceMode
        self.ipAllowListCount = detail.ipAllowList.count
        self.maintenanceScheduledAt = detail.maintenance?.scheduledAt
        self.environmentID = detail.environmentId
        self.createdAt = detail.createdAt
        self.updatedAt = detail.updatedAt
    }
}

/// Connection details from `GET /key-value/{id}/connection-info`. Every field is a secret.
struct KeyValueConnectionModel: Hashable, Sendable {
    let internalConnectionString: String
    let externalConnectionString: String
    let cliCommand: String

    init(_ info: Components.Schemas.KeyValueConnectionInfo) {
        self.internalConnectionString = info.internalConnectionString
        self.externalConnectionString = info.externalConnectionString
        self.cliCommand = info.cliCommand
    }
}

/// Backs the Key Value detail screen. Same shape as `PostgresDetailStore`, with the smaller action
/// set the API offers.
@MainActor
@Observable
final class KeyValueDetailStore {
    private(set) var instance: KeyValueDetailModel?
    private(set) var connection: KeyValueConnectionModel?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// Set when the connection-info call failed while the instance itself loaded — the connection
    /// section then says so rather than blanking the whole screen.
    private(set) var connectionErrorMessage: String?
    /// Set while an action's request is in flight, to disable the menu and show which one is running.
    private(set) var actionInFlight: KeyValueAction?
    /// Outcome banner for the last action — success or failure.
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, Equatable {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private let client: RenderClient
    let keyValueID: String
    /// Interval between polls while the status is transitional.
    private let pollInterval: Duration
    private var pollTask: Task<Void, Never>?

    init(client: RenderClient, keyValueID: String, pollInterval: Duration = .seconds(6)) {
        self.client = client
        self.keyValueID = keyValueID
        self.pollInterval = pollInterval
    }

    /// Actions offered for the current instance. Empty until the detail loads.
    var availableActions: [KeyValueAction] {
        guard let instance else { return [] }
        return [instance.isSuspended ? .resume : .suspend]
    }

    /// Loads the instance and its connection info together, then resumes polling if mid-transition.
    func load() async {
        isLoading = instance == nil
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
    func perform(_ action: KeyValueAction) async {
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

    /// The one place a `KeyValueAction` becomes an API call. Both endpoints answer 202. The path
    /// parameter is spelled `redisId` — a legacy of the endpoints' `/redis` ancestry.
    private func send(_ action: KeyValueAction) async throws {
        switch action {
        case .suspend:
            _ = try await client.api.suspendKeyValue(path: .init(redisId: keyValueID)).accepted
        case .resume:
            _ = try await client.api.resumeKeyValue(path: .init(redisId: keyValueID)).accepted
        }
    }

    private func reload() async {
        let client = client
        let keyValueID = keyValueID
        // Independent calls, so overlap them. The connection leg reports its own failure instead
        // of throwing: losing credentials display shouldn't blank a screen whose instance loaded.
        async let connectionAttempt: Result<KeyValueConnectionModel, any Error> = {
            do {
                let info = try await client.api
                    .retrieveKeyValueConnectionInfo(path: .init(redisId: keyValueID))
                    .ok.body.json
                return .success(KeyValueConnectionModel(info))
            } catch {
                return .failure(error)
            }
        }()

        do {
            let detail = try await client.api
                .retrieveKeyValue(path: .init(redisId: keyValueID))
                .ok.body.json
            self.instance = KeyValueDetailModel(detail)
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
    /// instance costs no requests at all.
    private func startPollingIfNeeded() {
        guard instance?.status.isTransitional == true else {
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
                if self.instance?.status.isTransitional != true {
                    self.pollTask = nil
                    return
                }
            }
        }
    }
}
