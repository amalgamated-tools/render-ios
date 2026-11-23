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

/// A project's environments.
@MainActor
@Observable
final class ProjectDetailStore {
    /// Sorted by name.
    private(set) var environments: [EnvironmentSummary] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?

    let project: ProjectSummary
    private let client: RenderClient
    /// Bumped by every load, so an older load that finishes late can't overwrite a newer one.
    private var generation = 0

    init(client: RenderClient, project: ProjectSummary) {
        self.client = client
        self.project = project
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

    let environment: EnvironmentSummary
    let ownerID: String
    private let client: RenderClient
    private var generation = 0

    init(client: RenderClient, ownerID: String, environment: EnvironmentSummary) {
        self.client = client
        self.ownerID = ownerID
        self.environment = environment
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

    private nonisolated static func attempt<T: Sendable>(
        _ work: @Sendable () async throws -> [T]
    ) async -> Result<[T], Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func byName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
