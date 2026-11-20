import Foundation
import RenderAPI

/// One maintenance run Render has scheduled for a resource in the workspace.
struct MaintenanceRun: Identifiable, Hashable, Sendable {
    enum State: Hashable, Sendable {
        case scheduled, inProgress, userFixRequired, cancelled, succeeded, failed
        /// A state the app doesn't know yet; the raw value is shown as-is.
        case other(String)

        init(raw: String) {
            switch raw {
            case "scheduled": self = .scheduled
            case "in_progress": self = .inProgress
            case "user_fix_required": self = .userFixRequired
            case "cancelled": self = .cancelled
            case "succeeded": self = .succeeded
            case "failed": self = .failed
            default: self = .other(raw)
            }
        }

        var title: String {
            switch self {
            case .scheduled: "Scheduled"
            case .inProgress: "In progress"
            case .userFixRequired: "Needs your fix"
            case .cancelled: "Cancelled"
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .other(let raw): raw.replacingOccurrences(of: "_", with: " ").capitalized
            }
        }

        /// Only a run that hasn't started can be moved or started early.
        var isActionable: Bool { self == .scheduled }

        var isFinished: Bool {
            switch self {
            case .cancelled, .succeeded, .failed: true
            default: false
            }
        }
    }

    let id: String
    let resourceID: String
    var resourceName: String?
    var state: State
    var scheduledAt: Date
    /// The latest Render will let the run be pushed back to.
    let pendingMaintenanceBy: Date?

    var displayName: String { resourceName ?? resourceID }
}

/// The workspace's maintenance runs: list, reschedule and run now.
///
/// What the live API showed, which shaped this:
/// - `GET /maintenance` returns a plain array with no cursor, so one request loads everything.
/// - An unknown run ID is `404`, and an unknown `state` filter is `400`.
/// - Render schedules runs itself, so the test workspace had none; the writes are documented as `202`
///   with no body and haven't been tried live, so any 2xx is accepted (see `NoContentWrite`).
/// - A run's `state` is free text in responses (`Scripts/maintenance-quirks.py`), so a state Render
///   adds later doesn't break the whole list.
@MainActor
@Observable
final class MaintenanceStore {
    /// Upcoming runs first, soonest first; finished runs after, newest first.
    private(set) var runs: [MaintenanceRun] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isSaving = false
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private let client: RenderClient
    let ownerID: String
    /// Bumped by every load and by every write, when it starts and when it ends, so a refresh that
    /// overlaps a write can't put back what the write changed.
    private var generation = 0
    /// The current time; tests fix it so their dates stay in the future.
    private let now: @Sendable () -> Date
    /// Writes Render accepted but may not show yet: both are asynchronous (`202`), so a list fetched
    /// just after one can still have the old time or state. Keyed by run ID.
    private var pending: [String: PendingChange] = [:]

    /// What a write changed, kept over newer lists until one shows it or it expires.
    private struct PendingChange {
        var scheduledAt: Date?
        var started = false
        var expires: Date
    }

    /// How long an accepted write outranks a list that doesn't show it yet. After this the list wins,
    /// so a write Render dropped doesn't stay on screen forever.
    static let pendingWindow: TimeInterval = 120

    init(client: RenderClient, ownerID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.ownerID = ownerID
        self.now = now
    }

    var upcoming: [MaintenanceRun] { runs.filter { !$0.state.isFinished } }
    var finished: [MaintenanceRun] { runs.filter(\.state.isFinished) }

    func run(id: String) -> MaintenanceRun? { runs.first { $0.id == id } }

    func load() async {
        generation += 1
        let current = generation
        let client = client
        let ownerID = ownerID
        do {
            let listed = try await client.api
                .listMaintenance(query: .init(ownerId: [ownerID]))
                .ok.body.json
                .map {
                    MaintenanceRun(
                        id: $0.id,
                        resourceID: $0.resourceId,
                        resourceName: nil,
                        state: .init(raw: $0.state),
                        scheduledAt: $0.scheduledAt,
                        pendingMaintenanceBy: $0.pendingMaintenanceBy
                    )
                }
            let names = await Self.resourceNames(for: Set(listed.map(\.resourceID)), client: client)
            guard current == generation else { return }
            runs = Self.sorted(reconcile(listed).map { run in
                var run = run
                run.resourceName = names[run.resourceID] ?? nil
                return run
            })
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = Self.message(for: error)
        }
        hasLoaded = true
    }

    /// Moves a scheduled run. Returns whether Render accepted it.
    @discardableResult
    func reschedule(_ run: MaintenanceRun, to date: Date) async -> Bool {
        // The sheet holds a copy of the run; a refresh since it opened may have changed its state or deadline.
        guard !isSaving else { return false }
        guard let run = self.run(id: run.id), run.state.isActionable else {
            actionResult = Self.noLongerScheduled
            return false
        }
        // The sheet can stay open past the time it shows, so check again here.
        if date <= now() {
            actionResult = ActionResult(message: "Choose a time in the future.", isFailure: true)
            return false
        }
        // The request says `scheduledAt` must be *before* the deadline, so the deadline itself is refused.
        if let latest = run.pendingMaintenanceBy, date >= latest {
            actionResult = ActionResult(
                message: "Maintenance must start before \(latest.formatted(date: .abbreviated, time: .shortened)).",
                isFailure: true
            )
            return false
        }
        beginWrite()
        defer { endWrite() }
        do {
            try await client.api.updateMaintenance(
                path: .init(maintenanceRunID: run.id),
                body: .json(.init(scheduledAt: date))
            ).expectSuccess()
            update(run.id) { $0.scheduledAt = date }
            remember(run.id) { $0.scheduledAt = date }
            actionResult = ActionResult(message: "Rescheduled maintenance for \(run.displayName).", isFailure: false)
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    /// Starts a scheduled run now. Returns whether Render accepted it.
    @discardableResult
    func trigger(_ run: MaintenanceRun) async -> Bool {
        // The confirmation holds a copy of the run; act on what the list shows now.
        guard !isSaving else { return false }
        guard let run = self.run(id: run.id), run.state.isActionable else {
            actionResult = Self.noLongerScheduled
            return false
        }
        beginWrite()
        defer { endWrite() }
        do {
            try await client.api.triggerMaintenance(path: .init(maintenanceRunID: run.id)).expectSuccess()
            // Render starts it asynchronously; show it as started rather than wait for the next load.
            update(run.id) { $0.state = .inProgress }
            remember(run.id) { $0.started = true }
            actionResult = ActionResult(message: "Started maintenance for \(run.displayName).", isFailure: false)
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    /// A refresh since the sheet or dialog opened shows the run has started, finished or gone.
    private static let noLongerScheduled = ActionResult(
        message: "This maintenance run is no longer scheduled.",
        isFailure: true
    )

    func dismissActionResult() {
        actionResult = nil
    }

    // MARK: - Internals

    private func beginWrite() {
        isSaving = true
        actionResult = nil
        generation += 1
    }

    private func endWrite() {
        generation += 1
        isSaving = false
    }

    private func update(_ id: String, _ change: (inout MaintenanceRun) -> Void) {
        guard let index = runs.firstIndex(where: { $0.id == id }) else { return }
        change(&runs[index])
        runs = Self.sorted(runs)
    }

    private func remember(_ id: String, _ change: (inout PendingChange) -> Void) {
        var entry = pending[id] ?? PendingChange(expires: now())
        change(&entry)
        entry.expires = now().addingTimeInterval(Self.pendingWindow)
        pending[id] = entry
    }

    /// Lays accepted writes over a fresh list. A write the list already shows, or one that has expired,
    /// is dropped; so is one whose run is gone from the list.
    private func reconcile(_ listed: [MaintenanceRun]) -> [MaintenanceRun] {
        let now = now()
        var kept: [String: PendingChange] = [:]
        let result = listed.map { run -> MaintenanceRun in
            guard var entry = pending[run.id], now < entry.expires else { return run }
            var run = run
            if let date = entry.scheduledAt {
                if run.scheduledAt == date { entry.scheduledAt = nil } else { run.scheduledAt = date }
            }
            if entry.started {
                // Any state but `scheduled` means Render has picked the trigger up.
                if run.state != .scheduled { entry.started = false } else { run.state = .inProgress }
            }
            if entry.scheduledAt != nil || entry.started { kept[run.id] = entry }
            return run
        }
        pending = kept
        return result
    }

    /// Looks up each resource's name by its ID prefix. A name that can't be found is nil and the ID is
    /// shown instead; a failed lookup never fails the list.
    private static func resourceNames(for ids: Set<String>, client: RenderClient) async -> [String: String?] {
        await withTaskGroup(of: (String, String?).self) { group in
            for id in ids {
                group.addTask {
                    let name: String?
                    if id.hasPrefix("srv-") || id.hasPrefix("crn-") {
                        name = try? await client.api.retrieveService(path: .init(serviceId: id)).ok.body.json.name
                    } else if id.hasPrefix("dpg-") {
                        name = try? await client.api.retrievePostgres(path: .init(postgresId: id)).ok.body.json.name
                    } else if id.hasPrefix("red-") {
                        name = try? await client.api.retrieveKeyValue(path: .init(redisId: id)).ok.body.json.name
                    } else {
                        name = nil
                    }
                    return (id, name)
                }
            }
            var names: [String: String?] = [:]
            for await (id, name) in group { names[id] = name }
            return names
        }
    }

    static func sorted(_ runs: [MaintenanceRun]) -> [MaintenanceRun] {
        let upcoming = runs.filter { !$0.state.isFinished }.sorted { $0.scheduledAt < $1.scheduledAt }
        let finished = runs.filter(\.state.isFinished).sorted { $0.scheduledAt > $1.scheduledAt }
        return upcoming + finished
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
