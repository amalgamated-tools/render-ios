import Foundation
import Observation
import RenderAPI

/// An environment as the project screens show it. Domain projection of
/// `Components.Schemas.Environment`.
struct EnvironmentSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let projectID: String
    let isProtected: Bool
    let networkIsolationEnabled: Bool
    let serviceCount: Int
    /// Postgres and Key Value together. Render lists Key Value under its old name, `redisIds`.
    let databaseCount: Int
    let envGroupCount: Int

    init(_ environment: Components.Schemas.Environment) {
        self.id = environment.id
        self.name = environment.name
        self.projectID = environment.projectId
        self.isProtected = environment.protectedStatus == .protected
        self.networkIsolationEnabled = environment.networkIsolationEnabled
        self.serviceCount = environment.serviceIds.count
        self.databaseCount = environment.databasesIds.count + environment.redisIds.count
        self.envGroupCount = environment.envGroupIds.count
    }

    /// Render deletes an environment only when this is true. The four counts cover every kind of
    /// resource `Environment` lists.
    var isEmpty: Bool {
        serviceCount == 0 && databaseCount == 0 && envGroupCount == 0
    }
}

/// Render's answer when an environment it was asked to delete still holds resources.
private func isNotEmptyConflict(_ error: any Error) -> Bool {
    if case .client(statusCode: 409, _) = RenderError.wrapping(error) { return true }
    return false
}

/// True when a delete found nothing to delete: most likely `RetryMiddleware` repeated a DELETE
/// whose first answer was lost, or it was deleted elsewhere. Either way it's gone, as asked.
private func isAlreadyGone(_ error: any Error) -> Bool {
    if case .notFound = RenderError.wrapping(error) { return true }
    return false
}

/// The outcome of a rename, settings change, or move on the project screens.
struct ProjectActionResult: Identifiable, ActionOutcome {
    let id = UUID()
    let message: String
    let isFailure: Bool

    static func failure(_ error: any Error) -> ProjectActionResult {
        ProjectActionResult(message: RenderError.wrapping(error).errorDescription ?? "Something went wrong.", isFailure: true)
    }
}

/// A project's environments, plus renaming the project.
@MainActor
@Observable
final class ProjectDetailStore {
    /// Sorted by name.
    private(set) var environments: [EnvironmentSummary] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    private(set) var project: ProjectSummary
    private(set) var isSaving = false
    private(set) var actionResult: ProjectActionResult?
    /// Set once Render has deleted the project, so the screen closes and nothing reloads it.
    private(set) var isDeleted = false

    private let client: RenderClient
    private let onProjectChange: (ProjectSummary) -> Void
    private let onProjectDelete: (ProjectSummary) -> Void
    /// Bumped by every load, so an older load that finishes late can't overwrite a newer one.
    private var generation = 0
    /// Environments changed on their own screen since the current load started. Render's answer to
    /// that change is newer than anything the load fetched, so it's applied over the load's result.
    private var changedSinceLoad: [String: EnvironmentSummary] = [:]
    /// Environments created or deleted since the current load started, which it may not reflect.
    private var createdSinceLoad: [EnvironmentSummary] = []
    private var deletedSinceLoad: Set<String> = []

    /// - Parameters:
    ///   - onProjectChange: Receives the project after a rename, or after an environment is created
    ///     or deleted, so the shared `ProjectsStore` (the scope picker and the Projects list) shows
    ///     its new name and scopes the service list to its current environments.
    ///   - onProjectDelete: Receives the project once Render has deleted it.
    init(
        client: RenderClient,
        project: ProjectSummary,
        onProjectChange: @escaping (ProjectSummary) -> Void = { _ in },
        onProjectDelete: @escaping (ProjectSummary) -> Void = { _ in }
    ) {
        self.client = client
        self.project = project
        self.onProjectChange = onProjectChange
        self.onProjectDelete = onProjectDelete
    }

    /// Render deletes a project only when every environment in it is empty.
    var canDeleteProject: Bool {
        hasLoaded && errorMessage == nil && environments.allSatisfy(\.isEmpty)
    }

    /// The environments a resource in `environment` could move to.
    func destinations(from environment: EnvironmentSummary) -> [EnvironmentSummary] {
        environments.filter { $0.id != environment.id }
    }

    func rename(to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving, !name.isEmpty, name != project.name else { return }
        isSaving = true
        actionResult = nil
        defer { isSaving = false }
        do {
            let updated = try await client.api.updateProject(
                path: .init(projectId: project.id),
                body: .json(.init(name: name))
            ).ok.body.json
            project = ProjectSummary(updated)
            onProjectChange(project)
            actionResult = ProjectActionResult(message: "Renamed to \(project.name).", isFailure: false)
        } catch {
            actionResult = .failure(error)
        }
    }

    /// Takes a change made on an environment's screen. A load in flight keeps everything else it
    /// fetched, and this environment is applied over it when it finishes.
    func replace(_ environment: EnvironmentSummary) {
        guard let index = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        changedSinceLoad[environment.id] = environment
        environments[index] = environment
        environments.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func createEnvironment(name: String, isProtected: Bool) async -> EnvironmentSummary? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSaving, !isDeleted, !name.isEmpty else { return nil }
        isSaving = true
        actionResult = nil
        defer { isSaving = false }
        do {
            let created = try await client.api.createEnvironment(body: .json(.init(
                name: name,
                projectId: project.id,
                protectedStatus: isProtected ? .protected : .unprotected
            ))).created.body.json
            let environment = EnvironmentSummary(created)
            createdSinceLoad.append(environment)
            environments.append(environment)
            environments.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            setEnvironmentIDs(project.environmentIDs + [environment.id])
            actionResult = ProjectActionResult(message: "Created \(environment.name).", isFailure: false)
            return environment
        } catch {
            actionResult = .failure(error)
            return nil
        }
    }

    /// Takes an environment deleted on its own screen out of the list.
    func environmentDeleted(_ environment: EnvironmentSummary) {
        deletedSinceLoad.insert(environment.id)
        environments.removeAll { $0.id == environment.id }
        setEnvironmentIDs(project.environmentIDs.filter { $0 != environment.id })
        actionResult = ProjectActionResult(message: "Deleted \(environment.name).", isFailure: false)
    }

    /// Deletes the project, but only after a fresh look confirms every environment is empty.
    ///
    /// The check can't be left to Render. Asked to delete a project with a non-empty environment,
    /// Render answers 409, but only after deleting each empty environment it reached first,
    /// protected ones included. So the app refuses unless all of them are empty right now.
    /// - Returns: True once the project is gone.
    func deleteProject() async -> Bool {
        guard !isSaving, !isDeleted else { return false }
        isSaving = true
        actionResult = nil
        defer { isSaving = false }
        let current: [EnvironmentSummary]
        do {
            current = try await fetchEnvironments()
        } catch {
            actionResult = .failure(error)
            return false
        }
        // Anything loading now is older than this.
        generation += 1
        show(current)
        let occupied = environments.filter { !$0.isEmpty }
        guard occupied.isEmpty else {
            let names = ListFormatter.localizedString(byJoining: occupied.map(\.name))
            actionResult = ProjectActionResult(
                message: "Move or delete everything in \(names) first. Render deletes a project only when all its environments are empty.",
                isFailure: true
            )
            return false
        }
        do {
            try await client.api.deleteProject(path: .init(projectId: project.id)).expectSuccess()
        } catch {
            guard !isAlreadyGone(error) else { return finishDelete() }
            actionResult = isNotEmptyConflict(error)
                ? ProjectActionResult(message: "Render refused: something was added to an environment. Some empty environments may have been deleted.", isFailure: true)
                : .failure(error)
            // Render may have deleted some environments before refusing, so show what's left.
            if let remaining = try? await fetchEnvironments() {
                generation += 1
                show(remaining)
                setEnvironmentIDs(environments.map(\.id))
            }
            return false
        }
        return finishDelete()
    }

    private func finishDelete() -> Bool {
        isDeleted = true
        onProjectDelete(project)
        return true
    }

    func dismissActionResult() {
        actionResult = nil
    }

    func load() async {
        guard !isDeleted else { return }
        generation += 1
        let current = generation
        // A load starting now fetches after any earlier change, so it has nothing to apply over it.
        changedSinceLoad = [:]
        createdSinceLoad = []
        deletedSinceLoad = []
        do {
            let listed = try await fetchEnvironments()
            guard current == generation else { return }
            var merged = listed
                .filter { !deletedSinceLoad.contains($0.id) }
                .map { changedSinceLoad[$0.id] ?? $0 }
            merged += createdSinceLoad.filter { created in !merged.contains { $0.id == created.id } }
            show(merged)
            changedSinceLoad = [:]
            createdSinceLoad = []
            deletedSinceLoad = []
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
        }
        hasLoaded = true
    }

    private func fetchEnvironments() async throws -> [EnvironmentSummary] {
        let client = client
        let projectID = project.id
        return try await CursorPaginator(pageSize: 100) { cursor, limit in
            try await client.api
                .listEnvironments(query: .init(projectId: [projectID], cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { (envelope: Components.Schemas.EnvironmentWithCursor) in
            (EnvironmentSummary(envelope.environment), envelope.cursor)
        }.collect(limit: 500)
    }

    private func show(_ list: [EnvironmentSummary]) {
        environments = list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Keeps the shared project's environments in step, since the service list's project scope
    /// filters on them.
    private func setEnvironmentIDs(_ ids: [String]) {
        project = ProjectSummary(id: project.id, name: project.name, environmentIDs: ids)
        onProjectChange(project)
    }
}

/// The services, databases and env groups in one environment.
///
/// Each kind is its own request, filtered by `environmentId`. They load together but fail
/// separately, so one failing list can't hide the others: a kind that failed keeps whatever it
/// last showed, and `errorMessage` names what's missing.
@MainActor
@Observable
final class EnvironmentResourcesStore {
    private(set) var services: [ServiceSummary] = []
    private(set) var postgres: [PostgresSummary] = []
    private(set) var keyValues: [KeyValueSummary] = []
    private(set) var envGroups: [EnvGroupSummary] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    private(set) var environment: EnvironmentSummary
    private(set) var isSaving = false
    private(set) var actionResult: ProjectActionResult?

    let ownerID: String
    private let client: RenderClient
    private let onEnvironmentChange: (EnvironmentSummary) -> Void
    private let onResourcesChange: () -> Void
    private let onEnvironmentDelete: (EnvironmentSummary) -> Void
    private var generation = 0
    /// Set once Render has deleted the environment, so the screen closes and nothing reloads it.
    private(set) var isDeleted = false

    /// - Parameters:
    ///   - onEnvironmentChange: Receives the environment after a rename or settings change.
    ///   - onResourcesChange: Called after a resource moves or is removed, so the project screen
    ///     can reload its counts.
    init(
        client: RenderClient,
        ownerID: String,
        environment: EnvironmentSummary,
        onEnvironmentChange: @escaping (EnvironmentSummary) -> Void = { _ in },
        onResourcesChange: @escaping () -> Void = {},
        onEnvironmentDelete: @escaping (EnvironmentSummary) -> Void = { _ in }
    ) {
        self.client = client
        self.ownerID = ownerID
        self.environment = environment
        self.onEnvironmentChange = onEnvironmentChange
        self.onResourcesChange = onResourcesChange
        self.onEnvironmentDelete = onEnvironmentDelete
    }

    var isEmpty: Bool {
        services.isEmpty && postgres.isEmpty && keyValues.isEmpty && envGroups.isEmpty
    }

    /// Render deletes an environment only when it's empty. A list that failed to load can't be
    /// shown to be empty, so it blocks the delete too.
    var canDelete: Bool {
        hasLoaded && errorMessage == nil && isEmpty
    }

    /// Deletes this environment. Render refuses (409) if it holds anything, without deleting it.
    /// - Returns: True once the environment is gone.
    func delete() async -> Bool {
        guard !isSaving, !isDeleted, canDelete else { return false }
        isSaving = true
        actionResult = nil
        do {
            try await client.api.deleteEnvironment(path: .init(environmentId: environment.id)).expectSuccess()
        } catch {
            guard !isAlreadyGone(error) else { return finishDelete() }
            if isNotEmptyConflict(error) {
                actionResult = ProjectActionResult(message: "\(environment.name) isn't empty any more, so Render kept it.", isFailure: true)
                isSaving = false
                await load()
            } else {
                actionResult = .failure(error)
                isSaving = false
            }
            return false
        }
        return finishDelete()
    }

    private func finishDelete() -> Bool {
        isSaving = false
        isDeleted = true
        onEnvironmentDelete(environment)
        return true
    }

    func load() async {
        guard !isDeleted else { return }
        generation += 1
        let current = generation
        let client = client
        let ownerID = ownerID
        let environmentIDs = [environment.id]

        async let servicesResult = Self.attempt {
            try await CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listServices(query: .init(environmentId: environmentIDs, ownerId: [ownerID],
                                               cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { envelope in
                (ServiceSummary(envelope.service), envelope.cursor)
            }.collect(limit: 500)
        }
        async let postgresResult = Self.attempt {
            try await CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listPostgres(query: .init(ownerId: [ownerID], environmentId: environmentIDs,
                                               cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { envelope in
                (PostgresSummary(envelope.postgres), envelope.cursor)
            }.collect(limit: 500)
        }
        async let keyValueResult = Self.attempt {
            try await CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listKeyValue(query: .init(ownerId: [ownerID], environmentId: environmentIDs,
                                               cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { envelope in
                (KeyValueSummary(envelope.keyValue), envelope.cursor)
            }.collect(limit: 500)
        }
        async let envGroupsResult = Self.attempt {
            try await CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listEnvGroups(query: .init(ownerId: [ownerID], environmentId: environmentIDs,
                                                cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { envelope in
                (EnvGroupSummary(envelope.envGroup), envelope.cursor)
            }.collect(limit: 500)
        }

        let (loadedServices, loadedPostgres, loadedKeyValues, loadedEnvGroups) =
            await (servicesResult, postgresResult, keyValueResult, envGroupsResult)
        guard current == generation else { return }

        var failed: [String] = []
        var firstError: Error?
        func apply<T>(_ result: Result<[T], Error>, name: String, sort: (T, T) -> Bool, into keyPath: ReferenceWritableKeyPath<EnvironmentResourcesStore, [T]>) {
            switch result {
            case .success(let items):
                self[keyPath: keyPath] = items.sorted(by: sort)
            case .failure(let error):
                failed.append(name)
                if firstError == nil { firstError = error }
            }
        }
        apply(loadedServices, name: "services", sort: { Self.byName($0.name, $1.name) }, into: \.services)
        apply(loadedPostgres, name: "Postgres", sort: { Self.byName($0.name, $1.name) }, into: \.postgres)
        apply(loadedKeyValues, name: "Key Value", sort: { Self.byName($0.name, $1.name) }, into: \.keyValues)
        apply(loadedEnvGroups, name: "env groups", sort: { Self.byName($0.name, $1.name) }, into: \.envGroups)

        if let firstError {
            let reason = RenderError.wrapping(firstError).errorDescription ?? "Something went wrong."
            errorMessage = "Couldn't load \(ListFormatter.localizedString(byJoining: failed)). \(reason)"
        } else {
            errorMessage = nil
        }
        hasLoaded = true
    }

    // MARK: - Writes

    func rename(to name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != environment.name else { return }
        await update(.init(name: name)) { "Renamed to \($0.name)." }
    }

    func setProtected(_ isOn: Bool) async {
        guard isOn != environment.isProtected else { return }
        await update(.init(protectedStatus: isOn ? .protected : .unprotected)) {
            $0.isProtected ? "\($0.name) is protected." : "\($0.name) is no longer protected."
        }
    }

    func setNetworkIsolation(_ isOn: Bool) async {
        guard isOn != environment.networkIsolationEnabled else { return }
        await update(.init(networkIsolationEnabled: isOn)) {
            $0.networkIsolationEnabled ? "Network isolation on." : "Network isolation off."
        }
    }

    /// Moves a resource into `target`. Render keeps a resource in one environment at a time, so
    /// adding it there takes it out of this one.
    func move(resourceID: String, name: String, to target: EnvironmentSummary) async {
        await changeResources {
            // Render answers 201, not the documented 200. See `NoContentWrite`.
            try await $0.api.addResourcesToEnvironment(
                path: .init(environmentId: target.id),
                body: .json(.init(resourceIds: [resourceID]))
            ).expectSuccess()
            return "Moved \(name) to \(target.name)."
        }
    }

    /// Takes a resource out of this environment. It stays in the workspace, outside any project.
    func remove(resourceID: String, name: String) async {
        let environmentID = environment.id
        await changeResources {
            try await $0.api.removeResourcesFromEnvironment(
                path: .init(environmentId: environmentID),
                query: .init(resourceIds: [resourceID])
            ).expectSuccess()
            return "Removed \(name) from \(self.environment.name)."
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private func update(
        _ body: Components.Schemas.EnvironmentPATCHInput,
        message: (EnvironmentSummary) -> String
    ) async {
        guard !isSaving else { return }
        isSaving = true
        actionResult = nil
        defer { isSaving = false }
        do {
            let updated = try await client.api.updateEnvironment(
                path: .init(environmentId: environment.id),
                body: .json(body)
            ).ok.body.json
            environment = EnvironmentSummary(updated)
            onEnvironmentChange(environment)
            actionResult = ProjectActionResult(message: message(environment), isFailure: false)
        } catch {
            actionResult = .failure(error)
        }
    }

    /// Runs a move or removal, then reloads either way: on a failure Render may still have
    /// applied part of it (a retried request whose first answer was lost), so the list shows
    /// what's actually there rather than what the app assumed.
    private func changeResources(_ write: (RenderClient) async throws -> String) async {
        guard !isSaving else { return }
        isSaving = true
        actionResult = nil
        do {
            actionResult = ProjectActionResult(message: try await write(client), isFailure: false)
        } catch {
            actionResult = .failure(error)
        }
        await load()
        isSaving = false
        onResourcesChange()
    }

    private nonisolated static func attempt<T: Sendable>(
        _ work: @Sendable () async throws -> [T]
    ) async -> Result<[T], Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func byName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
