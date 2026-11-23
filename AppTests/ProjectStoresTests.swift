import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Projects: a project's environments, and the resources in one environment.
@MainActor
@Suite("Projects")
struct ProjectStoresTests {
    private static let project = decode(Components.Schemas.ProjectWithCursor.self,
                                        from: Fixtures.projectsPage([("prj-1", "shop", ["evm-1", "evm-2"])]),
                                        array: true).map { ProjectSummary($0.project) }!

    private nonisolated static func environment(id: String, name: String, protected: Bool = false,
                                                services: Int = 0, postgres: Int = 0, redis: Int = 0, groups: Int = 0) -> String {
        func ids(_ prefix: String, _ count: Int) -> String {
            "[" + (0..<count).map { #""\#(prefix)-\#($0)""# }.joined(separator: ",") + "]"
        }
        return #"{"environment":{"id":"\#(id)","name":"\#(name)","projectId":"prj-1","databasesIds":\#(ids("dpg", postgres)),"redisIds":\#(ids("red", redis)),"serviceIds":\#(ids("srv", services)),"envGroupIds":\#(ids("evg", groups)),"protectedStatus":"\#(protected ? "protected" : "unprotected")","networkIsolationEnabled":false},"cursor":"c-\#(id)"}"#
    }

    private static func sampleEnvironment() -> EnvironmentSummary {
        let json = #"{"id":"evm-1","name":"production","projectId":"prj-1","databasesIds":[],"redisIds":[],"serviceIds":[],"envGroupIds":[],"protectedStatus":"protected","networkIsolationEnabled":true}"#
        return EnvironmentSummary(decode(Components.Schemas.Environment.self, from: json)!)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String, array: Bool = false) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if array { return try? decoder.decode([T].self, from: Data(json.utf8)).first }
        return try? decoder.decode(T.self, from: Data(json.utf8))
    }

    @Test("a project's environments load by project ID, sorted, with their counts")
    func environmentsLoad() async throws {
        let body = "[" + [
            Self.environment(id: "evm-2", name: "staging", groups: 1),
            Self.environment(id: "evm-1", name: "production", protected: true, services: 2, postgres: 1, redis: 1),
        ].joined(separator: ",") + "]"
        let (client, transport) = methodRouted { _, _ in (200, body) }
        let store = ProjectDetailStore(client: client, project: Self.project)

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.environments.map(\.name) == ["production", "staging"])
        let production = try #require(store.environments.first)
        #expect(production.isProtected)
        #expect(production.databaseCount == 2)
        #expect(EnvironmentDisplay.counts(production) == "2 services · 2 databases · 0 env groups")
        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/environments?"))
        #expect(path.contains("projectId=prj-1"))
    }

    @Test("a failed refresh keeps the environments already shown")
    func failedRefreshKeepsEnvironments() async {
        let failing = LockedFlag()
        let (client, _) = methodRouted { _, _ in
            failing.value ? (500, #"{"message":"boom"}"#) : (200, "[" + Self.environment(id: "evm-1", name: "production") + "]")
        }
        let store = ProjectDetailStore(client: client, project: Self.project)
        await store.load()
        failing.value = true

        await store.load()

        #expect(store.environments.map(\.id) == ["evm-1"])
        #expect(store.errorMessage != nil)
    }

    @Test("an environment's four resource lists load filtered to that environment")
    func resourcesLoadFiltered() async throws {
        let (client, transport) = methodRouted { _, path in
            if path.hasPrefix("/services") { return (200, Fixtures.servicesPage([("srv-2", "worker"), ("srv-1", "api")])) }
            if path.hasPrefix("/postgres") { return (200, Fixtures.postgresPage([("dpg-1", "db")])) }
            if path.hasPrefix("/key-value") { return (200, Fixtures.keyValuePage([("red-1", "cache")])) }
            if path.hasPrefix("/env-groups") { return (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "shared")])) }
            return (404, #"{"message":"unexpected"}"#)
        }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.sampleEnvironment())

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.services.map(\.name) == ["api", "worker"])
        #expect(store.postgres.map(\.id) == ["dpg-1"])
        #expect(store.keyValues.map(\.id) == ["red-1"])
        #expect(store.envGroups.map(\.id) == ["evg-1"])
        let paths = transport.requests.compactMap(\.path)
        #expect(paths.count == 4)
        #expect(paths.allSatisfy { $0.contains("environmentId=evm-1") })
    }

    @Test("one failing resource list doesn't hide the others, and the error names it")
    func oneFailingListKeepsTheRest() async {
        let (client, _) = methodRouted { _, path in
            if path.hasPrefix("/services") { return (200, Fixtures.servicesPage([("srv-1", "api")])) }
            if path.hasPrefix("/postgres") { return (500, #"{"message":"boom"}"#) }
            if path.hasPrefix("/key-value") { return (200, "[]") }
            return (200, "[]")
        }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.sampleEnvironment())

        await store.load()

        #expect(store.services.map(\.id) == ["srv-1"])
        #expect(store.errorMessage?.hasPrefix("Couldn't load Postgres.") == true)
    }

    // MARK: - Writes

    private nonisolated static let environmentJSON = #"{"id":"evm-1","name":"prod","projectId":"prj-1","databasesIds":[],"redisIds":[],"serviceIds":[],"envGroupIds":[],"protectedStatus":"unprotected","networkIsolationEnabled":true}"#

    @Test("renaming a project sends only the name and tells the shared store")
    func renameProject() async throws {
        let renamed = #"{"id":"prj-1","name":"store","createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z","owner":{"id":"tea-1","name":"Team","email":"t@example.com","type":"team"},"environmentIds":["evm-1"]}"#
        let (client, sent) = recordingClient { method, _ in method == .patch ? (200, renamed) : (200, "[]") }
        var reported: ProjectSummary?
        let store = ProjectDetailStore(client: client, project: Self.project) { reported = $0 }

        await store.rename(to: "  store ")

        let patch = try #require(sent.all.first { $0.method == .patch })
        #expect(patch.path == "/projects/prj-1")
        #expect(patch.body.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\n", with: "") == #"{"name":"store"}"#)
        #expect(store.project.name == "store")
        #expect(reported?.name == "store")
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("an unchanged or blank name sends nothing")
    func renameNoOp() async {
        let (client, sent) = recordingClient { _, _ in (500, "") }
        let store = ProjectDetailStore(client: client, project: Self.project)

        await store.rename(to: Self.project.name)
        await store.rename(to: "   ")

        #expect(sent.all.isEmpty)
        #expect(store.actionResult == nil)
    }

    @Test("turning protection on sends protectedStatus and shows Render's answer")
    func protectEnvironment() async throws {
        let protected = Self.environmentJSON.replacingOccurrences(of: #""unprotected""#, with: #""protected""#)
        let (client, sent) = recordingClient { method, _ in method == .patch ? (200, protected) : (200, "[]") }
        var reported: EnvironmentSummary?
        let unprotected = EnvironmentSummary(Self.decode(Components.Schemas.Environment.self, from: Self.environmentJSON)!)
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: unprotected,
                                              onEnvironmentChange: { reported = $0 })

        await store.setProtected(true)

        let patch = try #require(sent.all.first { $0.method == .patch })
        #expect(patch.path == "/environments/evm-1")
        #expect(patch.body.contains(#""protectedStatus""#))
        #expect(!patch.body.contains("networkIsolationEnabled"))
        #expect(store.environment.isProtected)
        #expect(reported?.isProtected == true)
    }

    @Test("a failed settings change leaves the environment as it was and reports the error")
    func failedSettingsChange() async {
        let (client, _) = recordingClient { _, _ in (403, #"{"message":"forbidden"}"#) }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.sampleEnvironment())

        await store.setNetworkIsolation(false)

        #expect(store.environment.networkIsolationEnabled)
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("moving a resource adds it to the target, then reloads and tells the project screen")
    func moveResource() async throws {
        let (client, sent) = recordingClient { method, _ in
            // What Render really answers: 201, where the spec documents 200.
            if method == .post { return (201, Self.environmentJSON) }
            return (200, "[]")
        }
        var reloads = 0
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.sampleEnvironment(),
                                              onResourcesChange: { reloads += 1 })
        let staging = EnvironmentSummary(Self.decode(Components.Schemas.Environment.self,
                                                     from: Self.environmentJSON.replacingOccurrences(of: "evm-1", with: "evm-2"))!)

        await store.move(resourceID: "evg-1", name: "shared", to: staging)

        let post = try #require(sent.all.first { $0.method == .post })
        #expect(post.path == "/environments/evm-2/resources")
        #expect(post.body.contains("evg-1"))
        #expect(sent.all.filter { $0.method == .get }.count == 4)
        #expect(reloads == 1)
        #expect(store.actionResult?.isFailure == false)
        #expect(!store.isSaving)
    }

    @Test("removing a resource sends its ID to this environment, and a failure still reloads")
    func removeResource() async throws {
        let (client, sent) = recordingClient { method, _ in method == .delete ? (500, #"{"message":"boom"}"#) : (200, "[]") }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.sampleEnvironment())

        await store.remove(resourceID: "srv-1", name: "api")

        let delete = try #require(sent.all.first { $0.method == .delete })
        #expect(delete.path.hasPrefix("/environments/evm-1/resources?"))
        #expect(delete.path.contains("srv-1"))
        #expect(sent.all.filter { $0.method == .get }.count == 4)
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("a removal Render answers with a 2xx other than the documented 204 still succeeds")
    func removeUndocumentedSuccess() async {
        let (client, _) = recordingClient { method, _ in method == .delete ? (200, "{}") : (200, "[]") }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.sampleEnvironment())

        await store.remove(resourceID: "srv-1", name: "api")

        #expect(store.actionResult?.isFailure == false)
    }

    @Test("an environment change from its screen replaces the project's copy and drops a load in flight")
    func projectTakesEnvironmentChange() async {
        let (client, _) = methodRouted { _, _ in (200, "[" + Self.environment(id: "evm-1", name: "production") + "]") }
        let store = ProjectDetailStore(client: client, project: Self.project)
        await store.load()

        let renamed = EnvironmentSummary(Self.decode(Components.Schemas.Environment.self,
                                                 from: Self.environmentJSON.replacingOccurrences(of: #""prod""#, with: #""live""#))!)
        store.replace(renamed)

        #expect(store.environments.map(\.name) == ["live"])
        #expect(store.destinations(from: renamed).isEmpty)
    }
}
