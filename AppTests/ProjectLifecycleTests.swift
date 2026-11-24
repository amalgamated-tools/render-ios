import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Creating and deleting projects and environments.
@MainActor
@Suite("Project lifecycle")
struct ProjectLifecycleTests {
    private static let project = ProjectSummary(id: "prj-1", name: "shop", environmentIDs: ["evm-1", "evm-2"])

    /// One project as Render returns it from a create, taken from the list fixture.
    private nonisolated static func projectJSON(id: String, name: String, environmentIDs: [String]) -> String {
        let page = Fixtures.projectsPage([(id, name, environmentIDs)])
        let array = try! JSONSerialization.jsonObject(with: Data(page.utf8)) as! [[String: Any]]
        let data = try! JSONSerialization.data(withJSONObject: array[0]["project"]!)
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func environmentJSON(id: String, name: String, groups: Int = 0, protected: Bool = false) -> String {
        let ids = "[" + (0..<groups).map { #""evg-\#($0)""# }.joined(separator: ",") + "]"
        return #"{"id":"\#(id)","name":"\#(name)","projectId":"prj-1","databasesIds":[],"redisIds":[],"serviceIds":[],"envGroupIds":\#(ids),"protectedStatus":"\#(protected ? "protected" : "unprotected")","networkIsolationEnabled":false}"#
    }

    private nonisolated static func environmentsPage(_ environments: [(id: String, name: String, groups: Int)]) -> String {
        "[" + environments.map { #"{"environment":\#(environmentJSON(id: $0.id, name: $0.name, groups: $0.groups)),"cursor":"c-\#($0.id)"}"# }
            .joined(separator: ",") + "]"
    }

    private static func emptyEnvironment() -> EnvironmentSummary {
        let decoder = JSONDecoder()
        let schema = try! decoder.decode(Components.Schemas.Environment.self,
                                         from: Data(environmentJSON(id: "evm-1", name: "staging").utf8))
        return EnvironmentSummary(schema)
    }

    // MARK: - Create

    @Test("creating a project sends its name, owner and first environment, then lists it in order")
    func createProject() async throws {
        let (client, sent) = recordingClient { method, _ in
            method == .post
                ? (201, Self.projectJSON(id: "prj-9", name: "blog", environmentIDs: ["evm-9"]))
                : (200, Fixtures.projectsPage([("prj-1", "shop", ["evm-1"])]))
        }
        let store = ProjectsStore(client: client, ownerID: Fixtures.ownerID, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.load()

        let created = await store.create(name: "  blog ", environmentName: "production")

        #expect(created?.id == "prj-9")
        #expect(store.projects.map(\.name) == ["blog", "shop"])
        #expect(store.actionResult?.isFailure == false)
        let post = try #require(sent.all.first { $0.method == .post })
        #expect(post.path == "/projects")
        let body = try #require(JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
        #expect(body["name"] as? String == "blog")
        #expect(body["ownerId"] as? String == Fixtures.ownerID)
        #expect((body["environments"] as? [[String: Any]])?.first?["name"] as? String == "production")
    }

    @Test("a refused project create reports why and adds nothing")
    func createProjectFails() async {
        let (client, _) = recordingClient { method, _ in
            method == .post ? (400, #"{"message":"name taken"}"#) : (200, "[]")
        }
        let store = ProjectsStore(client: client, ownerID: Fixtures.ownerID, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.load()

        let created = await store.create(name: "blog", environmentName: "production")

        #expect(created == nil)
        #expect(store.projects.isEmpty)
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("deleting the scoped project clears the scope, so the service list doesn't stay filtered to it")
    func removingScopedProjectClearsScope() async {
        let (client, _) = recordingClient { _, _ in (200, Fixtures.projectsPage([("prj-1", "shop", ["evm-1"])])) }
        let store = ProjectsStore(client: client, ownerID: Fixtures.ownerID, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.load()
        store.selectedProjectID = "prj-1"

        store.remove(Self.project)

        #expect(store.projects.isEmpty)
        #expect(store.selectedProjectID == nil)
    }

    @Test("the scope key changes when the selected project gains an environment, so scoped lists rebuild")
    func scopeKeyFollowsEnvironments() async {
        let (client, _) = recordingClient { _, _ in (200, Fixtures.projectsPage([("prj-1", "shop", ["evm-1"])])) }
        let store = ProjectsStore(client: client, ownerID: Fixtures.ownerID, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await store.load()
        #expect(store.selectedScopeKey == "")
        store.selectedProjectID = "prj-1"
        let before = store.selectedScopeKey

        store.replace(ProjectSummary(id: "prj-1", name: "shop", environmentIDs: ["evm-1", "evm-2"]))

        #expect(store.selectedScopeKey != before)
        #expect(store.selectedEnvironmentIDs == ["evm-1", "evm-2"])
        // A rename alone keeps the key, so the lists don't reload for nothing.
        let afterAdd = store.selectedScopeKey
        store.replace(ProjectSummary(id: "prj-1", name: "store", environmentIDs: ["evm-1", "evm-2"]))
        #expect(store.selectedScopeKey == afterAdd)
    }

    /// A `ProjectsStore` whose project list requests wait on `gate` once `reloading` is set, and
    /// then answer with `reloadPage`: what Render listed before the change the test makes meanwhile.
    private func heldReloadStore(
        firstPage: String, reloadPage: String, gate: LoadGate, reloading: LockedFlag
    ) -> ProjectsStore {
        let transport = StubTransport { request, _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields = [.contentType: "application/json"]
            if request.method == .post {
                response.status = .created
                return (response, HTTPBody(Self.projectJSON(id: "prj-9", name: "blog", environmentIDs: ["evm-9"])))
            }
            if reloading.value {
                await gate.hold()
                return (response, HTTPBody(reloadPage))
            }
            return (response, HTTPBody(firstPage))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        return ProjectsStore(client: client, ownerID: Fixtures.ownerID, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test("a project created during a reload stays listed when the reload finishes")
    func createDuringReload() async {
        let page = Fixtures.projectsPage([("prj-1", "shop", ["evm-1"])])
        let gate = LoadGate(), reloading = LockedFlag()
        let store = heldReloadStore(firstPage: page, reloadPage: page, gate: gate, reloading: reloading)
        await store.load()
        reloading.value = true

        let reload = Task { await store.load() }
        await gate.waitUntilEntered(count: 1)
        _ = await store.create(name: "blog", environmentName: "production")
        await gate.open()
        await reload.value

        #expect(store.projects.map(\.id) == ["prj-9", "prj-1"])
    }

    @Test("a project deleted during a reload isn't brought back by it")
    func removeDuringReload() async {
        let page = Fixtures.projectsPage([("prj-1", "shop", ["evm-1"]), ("prj-2", "wiki", ["evm-2"])])
        let gate = LoadGate(), reloading = LockedFlag()
        let store = heldReloadStore(firstPage: page, reloadPage: page, gate: gate, reloading: reloading)
        await store.load()
        reloading.value = true

        let reload = Task { await store.load() }
        await gate.waitUntilEntered(count: 1)
        store.remove(Self.project)
        await gate.open()
        await reload.value

        #expect(store.projects.map(\.id) == ["prj-2"])
    }

    @Test("an environment added during a reload keeps the project's new environment IDs")
    func changeDuringReload() async {
        let page = Fixtures.projectsPage([("prj-1", "shop", ["evm-1"])])
        let gate = LoadGate(), reloading = LockedFlag()
        let store = heldReloadStore(firstPage: page, reloadPage: page, gate: gate, reloading: reloading)
        await store.load()
        store.selectedProjectID = "prj-1"
        reloading.value = true

        let reload = Task { await store.load() }
        await gate.waitUntilEntered(count: 1)
        store.replace(ProjectSummary(id: "prj-1", name: "shop", environmentIDs: ["evm-1", "evm-3"]))
        await gate.open()
        await reload.value

        #expect(store.selectedEnvironmentIDs == ["evm-1", "evm-3"])
    }

    @Test("creating an environment sends the project and protection, and adds it to the project")
    func createEnvironment() async throws {
        let changed = LockedBox<ProjectSummary?>(nil)
        let (client, sent) = recordingClient { method, _ in
            method == .post
                ? (201, Self.environmentJSON(id: "evm-3", name: "preview", protected: true))
                : (200, Self.environmentsPage([("evm-1", "production", 0), ("evm-2", "staging", 0)]))
        }
        let store = ProjectDetailStore(client: client, project: Self.project, onProjectChange: { changed.value = $0 })
        await store.load()

        let created = await store.createEnvironment(name: "preview", isProtected: true)

        #expect(created?.id == "evm-3")
        #expect(store.environments.map(\.name) == ["preview", "production", "staging"])
        #expect(changed.value?.environmentIDs == ["evm-1", "evm-2", "evm-3"])
        let post = try #require(sent.all.first { $0.method == .post })
        #expect(post.path == "/environments")
        let body = try #require(JSONSerialization.jsonObject(with: Data(post.body.utf8)) as? [String: Any])
        #expect(body["projectId"] as? String == "prj-1")
        #expect(body["protectedStatus"] as? String == "protected")
    }

    // MARK: - Delete a project

    @Test("a project with a non-empty environment is never sent a DELETE")
    func deleteProjectRefusesWhenOccupied() async {
        // The screen loaded with both empty; by the time of the delete, staging has a group.
        let occupied = LockedFlag()
        let (client, sent) = recordingClient { _, _ in
            (200, Self.environmentsPage([("evm-1", "production", 0), ("evm-2", "staging", occupied.value ? 1 : 0)]))
        }
        let deleted = LockedFlag()
        let store = ProjectDetailStore(client: client, project: Self.project, onProjectDelete: { _ in deleted.value = true })
        await store.load()
        #expect(store.canDeleteProject)
        occupied.value = true

        let result = await store.deleteProject()

        #expect(!result)
        #expect(!deleted.value)
        #expect(!sent.all.contains { $0.method == .delete })
        #expect(store.actionResult?.message.contains("staging") == true)
        #expect(!store.canDeleteProject)
    }

    @Test("a project whose environments are all empty is deleted")
    func deleteEmptyProject() async throws {
        let (client, sent) = recordingClient { method, _ in
            method == .delete ? (204, "") : (200, Self.environmentsPage([("evm-1", "production", 0)]))
        }
        let deleted = LockedBox<ProjectSummary?>(nil)
        let store = ProjectDetailStore(client: client, project: Self.project, onProjectDelete: { deleted.value = $0 })
        await store.load()

        #expect(await store.deleteProject())

        #expect(store.isDeleted)
        #expect(deleted.value?.id == "prj-1")
        let delete = try #require(sent.all.first { $0.method == .delete })
        #expect(delete.path == "/projects/prj-1")
    }

    @Test("a project DELETE answered 404 counts as deleted, since a retry may have repeated it")
    func deleteProjectAlreadyGone() async {
        let (client, _) = recordingClient { method, _ in
            method == .delete ? (404, #"{"message":"not found"}"#) : (200, Self.environmentsPage([("evm-1", "production", 0)]))
        }
        let store = ProjectDetailStore(client: client, project: Self.project)
        await store.load()

        #expect(await store.deleteProject())
        #expect(store.isDeleted)
    }

    @Test("a 409 on a project delete reports it and shows the environments Render left")
    func deleteProjectConflictShowsWhatsLeft() async {
        // Render deletes empty environments before refusing, so afterwards only staging is left.
        let refused = LockedFlag()
        let (client, _) = recordingClient { method, _ in
            if method == .delete {
                refused.value = true
                return (409, #"{"message":"environment not empty"}"#)
            }
            return refused.value
                ? (200, Self.environmentsPage([("evm-2", "staging", 1)]))
                : (200, Self.environmentsPage([("evm-1", "production", 0), ("evm-2", "staging", 0)]))
        }
        let changed = LockedBox<ProjectSummary?>(nil)
        let store = ProjectDetailStore(client: client, project: Self.project, onProjectChange: { changed.value = $0 })
        await store.load()

        #expect(await !store.deleteProject())

        #expect(!store.isDeleted)
        #expect(store.actionResult?.isFailure == true)
        #expect(store.environments.map(\.id) == ["evm-2"])
        #expect(changed.value?.environmentIDs == ["evm-2"])
    }

    // MARK: - Delete an environment

    @Test("an empty environment is deleted and the project screen is told")
    func deleteEmptyEnvironment() async throws {
        let (client, sent) = recordingClient { method, _ in method == .delete ? (204, "") : (200, "[]") }
        let deleted = LockedBox<EnvironmentSummary?>(nil)
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.emptyEnvironment(),
                                              onEnvironmentDelete: { deleted.value = $0 })
        await store.load()

        #expect(await store.delete())

        #expect(store.isDeleted)
        #expect(deleted.value?.id == "evm-1")
        #expect(sent.all.first { $0.method == .delete }?.path == "/environments/evm-1")
    }

    @Test("an environment that isn't empty can't be deleted")
    func occupiedEnvironmentCannotDelete() async {
        let (client, sent) = recordingClient { _, path in
            path.hasPrefix("/env-groups")
                ? (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "shared")]))
                : (200, "[]")
        }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.emptyEnvironment())
        await store.load()

        #expect(!store.canDelete)
        #expect(await !store.delete())
        #expect(!sent.all.contains { $0.method == .delete })
    }

    @Test("an environment whose lists didn't all load can't be deleted")
    func failedListBlocksDelete() async {
        let (client, _) = recordingClient { _, path in path.hasPrefix("/postgres") ? (500, #"{"message":"boom"}"#) : (200, "[]") }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.emptyEnvironment())
        await store.load()

        #expect(store.isEmpty)
        #expect(!store.canDelete)
    }

    @Test("a 409 on an environment delete keeps it, explains, and reloads what's in it")
    func deleteEnvironmentConflict() async {
        let refused = LockedFlag()
        let (client, _) = recordingClient { method, path in
            if method == .delete {
                refused.value = true
                return (409, #"{"message":"not empty"}"#)
            }
            if refused.value, path.hasPrefix("/env-groups") {
                return (200, Fixtures.envGroupsPage([Fixtures.envGroupMeta(id: "evg-1", name: "shared")]))
            }
            return (200, "[]")
        }
        let deleted = LockedFlag()
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.emptyEnvironment(),
                                              onEnvironmentDelete: { _ in deleted.value = true })
        await store.load()

        #expect(await !store.delete())

        #expect(!store.isDeleted)
        #expect(!deleted.value)
        #expect(store.actionResult?.message.contains("isn't empty") == true)
        #expect(store.envGroups.map(\.id) == ["evg-1"])
        #expect(!store.isSaving)
    }

    @Test("an environment DELETE answered 404 counts as deleted")
    func deleteEnvironmentAlreadyGone() async {
        let (client, _) = recordingClient { method, _ in method == .delete ? (404, #"{"message":"not found"}"#) : (200, "[]") }
        let store = EnvironmentResourcesStore(client: client, ownerID: Fixtures.ownerID, environment: Self.emptyEnvironment())
        await store.load()

        #expect(await store.delete())
        #expect(store.isDeleted)
    }

    @Test("a deleted environment leaves the project list and isn't brought back by a reload already running")
    func environmentDeletedSurvivesReload() async {
        let gate = LoadGate()
        let reloading = LockedFlag()
        let transport = StubTransport { _, _, _ in
            if reloading.value { await gate.hold() }
            var response = HTTPResponse(status: .ok)
            response.headerFields = [.contentType: "application/json"]
            return (response, HTTPBody(Self.environmentsPage([("evm-1", "production", 0), ("evm-2", "staging", 0)])))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        let store = ProjectDetailStore(client: client, project: Self.project)
        await store.load()
        let staging = try! #require(store.environments.first { $0.id == "evm-2" })
        reloading.value = true

        let reload = Task { await store.load() }
        await gate.waitUntilEntered(count: 1)
        store.environmentDeleted(staging)
        await gate.open()
        await reload.value

        #expect(store.environments.map(\.id) == ["evm-1"])
    }
}

/// A value a stub's closure can set while the test reads it.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
