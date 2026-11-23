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

    private let client: RenderClient
    private let onProjectChange: (ProjectSummary) -> Void
    /// Bumped by every load, so an older load that finishes late can't overwrite a newer one.
    private var generation = 0

    /// - Parameter onProjectChange: Receives a renamed project, so the shared `ProjectsStore` (the
    ///   scope picker and the Projects list) shows the new name.
    init(client: RenderClient, project: ProjectSummary, onProjectChange: @escaping (ProjectSummary) -> Void = { _ in }) {
        self.client = client
        self.project = project
        self.onProjectChange = onProjectChange
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

    /// Takes a change made on an environment's screen. A load already in flight started before
    /// the change, so it's discarded.
    func replace(_ environment: EnvironmentSummary) {
        guard let index = environments.firstIndex(where: { $0.id == environment.id }) else { return }
        generation += 1
        environments[index] = environment
        environments.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    func load() async {
        generation += 1
        let current = generation
        let client = client
        let projectID = project.id
        do {
            let paginator = CursorPaginator(pageSize: 100) { cursor, limit in
                try await client.api
                    .listEnvironments(query: .init(projectId: [projectID], cursor: cursor, limit: limit))
                    .ok.body.json
            } unwrap: { (envelope: Components.Schemas.EnvironmentWithCursor) in
                (EnvironmentSummary(envelope.environment), envelope.cursor)
            }
            let listed = try await paginator.collect(limit: 500)
            guard current == generation else { return }
            environments = listed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
        }
        hasLoaded = true
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
    private var generation = 0

    /// - Parameters:
    ///   - onEnvironmentChange: Receives the environment after a rename or settings change.
    ///   - onResourcesChange: Called after a resource moves or is removed, so the project screen
    ///     can reload its counts.
    init(
        client: RenderClient,
        ownerID: String,
        environment: EnvironmentSummary,
        onEnvironmentChange: @escaping (EnvironmentSummary) -> Void = { _ in },
        onResourcesChange: @escaping () -> Void = {}
    ) {
        self.client = client
        self.ownerID = ownerID
        self.environment = environment
        self.onEnvironmentChange = onEnvironmentChange
        self.onResourcesChange = onResourcesChange
    }

    var isEmpty: Bool {
        services.isEmpty && postgres.isEmpty && keyValues.isEmpty && envGroups.isEmpty
    }

    func load() async {
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
