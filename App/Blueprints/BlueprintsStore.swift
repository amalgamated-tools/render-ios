import Foundation
import Observation
import RenderAPI
import SwiftUI

/// A Blueprint as the app shows it. The list and detail responses carry the same fields, inlined
/// separately, so this flattens them into one value.
struct Blueprint: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Render's raw status (`created`, `paused`, `in_sync`, `syncing`, `error`, or a newer one).
    let status: String
    let autoSync: Bool
    let repo: String
    let branch: String
    /// The Blueprint file's path in the repo.
    let path: String
    let lastSync: Date?
}

extension Blueprint {
    init(_ payload: Components.Schemas.BlueprintWithCursor.BlueprintPayload) {
        self.init(id: payload.id, name: payload.name, status: payload.status, autoSync: payload.autoSync,
                  repo: payload.repo, branch: payload.branch, path: payload.path, lastSync: payload.lastSync)
    }

    init(_ payload: Operations.RetrieveBlueprint.Output.Ok.Body.JsonPayload) {
        self.init(id: payload.id, name: payload.name, status: payload.status, autoSync: payload.autoSync,
                  repo: payload.repo, branch: payload.branch, path: payload.path, lastSync: payload.lastSync)
    }

    init(_ payload: Operations.UpdateBlueprint.Output.Ok.Body.JsonPayload) {
        self.init(id: payload.id, name: payload.name, status: payload.status, autoSync: payload.autoSync,
                  repo: payload.repo, branch: payload.branch, path: payload.path, lastSync: payload.lastSync)
    }
}

/// A resource a Blueprint manages.
struct BlueprintResource: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Render's raw type (`web_service`, `postgres`, `key_value`, …), an open set.
    let type: String

    /// Where tapping the resource goes, when the app has a screen it can open from just an ID.
    enum Destination: Hashable {
        case service
        case postgres
        case keyValue
    }

    var destination: Destination? {
        switch type {
        case "web_service", "static_site", "private_service", "background_worker", "cron_job": .service
        case "postgres": .postgres
        // `redis` is Key Value's old name; Render still reports it for older instances.
        case "key_value", "redis": .keyValue
        default: nil
        }
    }
}

/// One sync of a Blueprint against a commit.
struct BlueprintSync: Identifiable, Hashable, Sendable {
    let id: String
    let commitID: String
    let startedAt: Date?
    let completedAt: Date?
    /// Render's raw state (`created`, `pending`, `running`, `error`, `success`, or a newer one).
    let state: String

    init(id: String, commitID: String, startedAt: Date?, completedAt: Date?, state: String) {
        self.id = id
        self.commitID = commitID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.state = state
    }

    init(_ payload: Components.Schemas.SyncWithCursor.SyncPayload) {
        self.init(id: payload.id, commitID: payload.commit.id, startedAt: payload.startedAt,
                  completedAt: payload.completedAt, state: payload.state)
    }

    var shortCommit: String { String(commitID.prefix(7)) }
}

// MARK: - Display

/// Readable names and tints for the open sets of raw values. Unknown values still render, named
/// from their raw text, so a value Render adds later shows up instead of breaking the screen.
enum BlueprintDisplay {
    static func statusName(_ raw: String) -> String {
        switch raw {
        case "created": "Awaiting First Sync"
        case "paused": "Paused"
        case "in_sync": "In Sync"
        case "syncing": "Syncing"
        case "error": "Error"
        default: humanized(raw)
        }
    }

    static func statusTint(_ raw: String) -> Color {
        switch raw {
        case "in_sync": .green
        case "syncing": .blue
        case "error": .red
        case "paused": .orange
        default: .secondary
        }
    }

    static func statusImage(_ raw: String) -> String {
        switch raw {
        case "in_sync": "checkmark.circle.fill"
        case "syncing": "arrow.triangle.2.circlepath"
        case "error": "exclamationmark.triangle.fill"
        case "paused": "pause.circle.fill"
        default: "circle.dashed"
        }
    }

    static func syncStateName(_ raw: String) -> String {
        switch raw {
        case "created": "Created"
        case "pending": "Pending"
        case "running": "Running"
        case "error": "Failed"
        case "success": "Succeeded"
        default: humanized(raw)
        }
    }

    static func syncStateTint(_ raw: String) -> Color {
        switch raw {
        case "success": .green
        case "running": .blue
        case "error": .red
        default: .secondary
        }
    }

    static func syncStateImage(_ raw: String) -> String {
        switch raw {
        case "success": "checkmark.circle.fill"
        case "running": "arrow.triangle.2.circlepath"
        case "error": "xmark.octagon.fill"
        default: "clock"
        }
    }

    static func resourceTypeName(_ raw: String) -> String {
        switch raw {
        case "static_site": "Static Site"
        case "web_service": "Web Service"
        case "private_service": "Private Service"
        case "background_worker": "Background Worker"
        case "cron_job": "Cron Job"
        case "redis", "key_value": "Key Value"
        case "postgres": "Postgres"
        case "environment_group": "Environment Group"
        case "build_source": "Build Source"
        case "workflow": "Workflow"
        default: humanized(raw)
        }
    }

    static func resourceTypeImage(_ raw: String) -> String {
        switch raw {
        case "static_site": "doc.richtext"
        case "web_service": "globe"
        case "private_service": "lock.shield"
        case "background_worker": "gearshape.2"
        case "cron_job": "clock.arrow.circlepath"
        case "redis", "key_value": "bolt.horizontal"
        case "postgres": "cylinder.split.1x2"
        case "environment_group": "list.bullet.rectangle"
        case "workflow": "flowchart"
        default: "shippingbox"
        }
    }

    /// `in_sync` → "In sync".
    static func humanized(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "_", with: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

// MARK: - Stores

/// The workspace's Blueprints.
@MainActor
@Observable
final class BlueprintsStore {
    /// Sorted by name.
    private(set) var blueprints: [Blueprint] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// Reports a disconnect made on the detail screen.
    private(set) var actionResult: BlueprintDetailStore.ActionResult?

    private let client: RenderClient
    let ownerID: String
    /// Bumped by every load, so an older load that finishes late can't overwrite a newer one.
    private var generation = 0

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
    }

    func load() async {
        generation += 1
        let current = generation
        let client = client
        let ownerID = ownerID
        do {
            let paginator = CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listBlueprints(query: .init(ownerId: [ownerID], cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { envelope in
                (Blueprint(envelope.blueprint), envelope.cursor)
            }
            let listed = try await paginator.collect(limit: 500)
            guard current == generation else { return }
            blueprints = listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
        }
        hasLoaded = true
    }

    /// Takes a change made on the detail screen, so the list doesn't show stale values. A load
    /// already in flight was started before the change, so it's discarded.
    func replace(_ blueprint: Blueprint) {
        guard let index = blueprints.firstIndex(where: { $0.id == blueprint.id }) else { return }
        generation += 1
        blueprints[index] = blueprint
    }

    /// Drops a Blueprint disconnected from the detail screen, which closes straight afterwards, so
    /// the list reports it. Render may keep listing it briefly, so an in-flight load is discarded.
    func remove(_ blueprint: Blueprint) {
        generation += 1
        blueprints.removeAll { $0.id == blueprint.id }
        actionResult = BlueprintDetailStore.ActionResult(message: "Disconnected \(blueprint.name). Its resources stay.", isFailure: false)
    }

    func dismissActionResult() {
        actionResult = nil
    }
}

/// One Blueprint: its details, the resources it manages, and its recent syncs, plus switching
/// auto-sync and disconnecting it.
///
/// The syncs load alongside the details but fail on their own, so a history error can't hide the
/// Blueprint, and a details error can't hide the history.
@MainActor
@Observable
final class BlueprintDetailStore {
    private(set) var blueprint: Blueprint?
    /// Sorted by type, then name.
    private(set) var resources: [BlueprintResource] = []
    private(set) var errorMessage: String?
    private(set) var hasLoaded = false

    /// Most recent first, as Render returns them.
    private(set) var syncs: [BlueprintSync] = []
    private(set) var syncsErrorMessage: String?
    private(set) var hasLoadedSyncs = false

    /// The outcome of the last auto-sync change or disconnect.
    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private(set) var isSaving = false
    private(set) var actionResult: ActionResult?
    /// Set once Render confirms the disconnect; the Blueprint no longer exists after that.
    private(set) var isDisconnected = false

    let blueprintID: String
    private let client: RenderClient
    private let syncLimit: Int
    /// Bumped by every load and write, so a load that started before a write can't overwrite it.
    private var generation = 0

    init(client: RenderClient, blueprintID: String, initial: Blueprint? = nil, syncLimit: Int = 20) {
        self.client = client
        self.blueprintID = blueprintID
        self.blueprint = initial
        self.syncLimit = syncLimit
    }

    func load() async {
        // A pull-to-refresh after the disconnect would only fetch a 404.
        guard !isDisconnected else { return }
        generation += 1
        let current = generation
        async let details: Void = loadDetails(generation: current)
        async let history: Void = loadSyncs(generation: current)
        _ = await (details, history)
    }

    private func loadDetails(generation current: Int) async {
        do {
            let payload = try await client.api
                .retrieveBlueprint(path: .init(blueprintId: blueprintID))
                .ok.body.json
            guard current == generation else { return }
            blueprint = Blueprint(payload)
            resources = payload.resources
                .map { BlueprintResource(id: $0.id, name: $0.name, type: $0._type) }
                .sorted {
                    let lhs = BlueprintDisplay.resourceTypeName($0.type), rhs = BlueprintDisplay.resourceTypeName($1.type)
                    if lhs != rhs { return lhs < rhs }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = Self.message(for: error)
        }
        hasLoaded = true
    }

    private func loadSyncs(generation current: Int) async {
        do {
            let page = try await client.api
                .listBlueprintSyncs(path: .init(blueprintId: blueprintID), query: .init(limit: syncLimit))
                .ok.body.json
            guard current == generation else { return }
            syncs = page.map { BlueprintSync($0.sync) }
            syncsErrorMessage = nil
        } catch {
            guard current == generation else { return }
            syncsErrorMessage = Self.message(for: error)
        }
        hasLoadedSyncs = true
    }

    // MARK: - Writes

    /// Switches whether Render re-syncs on every push to the Blueprint's branch. Returns the
    /// updated Blueprint, or nil if nothing changed.
    @discardableResult
    func setAutoSync(_ isOn: Bool) async -> Blueprint? {
        guard !isSaving, !isDisconnected, let current = blueprint, current.autoSync != isOn else { return nil }
        beginWrite()
        defer { endWrite() }
        do {
            let updated = try await client.api.updateBlueprint(
                path: .init(blueprintId: blueprintID),
                body: .json(.init(autoSync: isOn))
            ).ok.body.json
            let blueprint = Blueprint(updated)
            self.blueprint = blueprint
            actionResult = ActionResult(message: isOn ? "Auto-sync on." : "Auto-sync off.", isFailure: false)
            return blueprint
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return nil
        }
    }

    /// Disconnects the Blueprint: Render stops syncing from its file. The resources it managed
    /// stay. Returns whether Render confirmed it.
    @discardableResult
    func disconnect() async -> Bool {
        guard !isSaving, !isDisconnected else { return false }
        beginWrite()
        defer { endWrite() }
        do {
            _ = try await client.api.disconnectBlueprint(path: .init(blueprintId: blueprintID)).noContent
            isDisconnected = true
            actionResult = ActionResult(message: "Disconnected \(blueprint?.name ?? "Blueprint"). Its resources stay.", isFailure: false)
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private func beginWrite() {
        isSaving = true
        actionResult = nil
        generation += 1
    }

    private func endWrite() {
        generation += 1
        isSaving = false
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
