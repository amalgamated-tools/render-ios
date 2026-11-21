import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Shapes copied from what the live API answered for a sample workflow in a test workspace.
private enum WorkflowJSON {
    static func workflow(
        id: String = "wfl-1",
        name: String = "sample",
        slug: String? = "sample",
        defaultVersionID: String? = "wfv-2"
    ) -> String {
        let slugField = slug.map { #","slug":"\#($0)""# } ?? ""
        let versionField = defaultVersionID.map { #","defaultVersionId":"\#($0)""# } ?? ""
        return """
            {"autoDeployTrigger":"commit","buildConfig":{"branch":"main","buildCommand":"pip install -r requirements.txt",\
            "repo":"https://github.com/example/sample","rootDir":"","runtime":"python"},\
            "createdAt":"2026-11-21T17:51:02Z","id":"\(id)","name":"\(name)","ownerId":"tea-1",\
            "region":"oregon","runCommand":"python main.py","updatedAt":"2026-11-21T17:51:44Z"\(slugField)\(versionField)}
            """
    }

    static func workflowsPage(_ workflows: [String]) -> String {
        "[" + workflows.enumerated().map { #"{"cursor":"c\#($0.offset)","workflow":\#($0.element)}"# }
            .joined(separator: ",") + "]"
    }

    static func version(_ id: String, name: String, status: String, createdAt: String) -> String {
        #"{"cursor":"c-\#(id)","workflowVersion":{"createdAt":"\#(createdAt)","id":"\#(id)","name":"\#(name)","status":"\#(status)","workflowId":"wfl-1"}}"#
    }

    static func entry(_ key: String, id: String, name: String, version: String) -> String {
        #"{"cursor":"c-\#(id)","\#(key)":{"createdAt":"2026-11-21T17:51:43Z","id":"\#(id)","name":"\#(name)","workflowId":"wfl-1","workflowVersionId":"\#(version)"}}"#
    }

    /// Two builds of the same code: v1 (older, ready) and v2 (newer, ready), each registering the
    /// same tasks, plus a v3 that failed to build and registered nothing.
    static let versions = "[" + [
        version("wfv-1", name: "aaa111", status: "ready", createdAt: "2026-11-20T10:00:00Z"),
        version("wfv-3", name: "ccc333", status: "build_failed", createdAt: "2026-11-21T12:00:00Z"),
        version("wfv-2", name: "bbb222", status: "ready", createdAt: "2026-11-21T10:00:00Z"),
    ].joined(separator: ",") + "]"

    static let tasks = "[" + [
        entry("task", id: "tsk-1a", name: "square", version: "wfv-1"),
        entry("task", id: "tsk-1b", name: "slow", version: "wfv-1"),
        entry("task", id: "tsk-2a", name: "square", version: "wfv-2"),
        entry("task", id: "tsk-2b", name: "slow", version: "wfv-2"),
        entry("task", id: "tsk-2c", name: "fail", version: "wfv-2"),
    ].joined(separator: ",") + "]"

    static let flows = "[" + [
        entry("flow", id: "flw-1", name: "describe", version: "wfv-1"),
        entry("flow", id: "flw-2", name: "describe", version: "wfv-2"),
    ].joined(separator: ",") + "]"

    static func route(for path: String) -> (Int, String) {
        if path.contains("/workflowversions") { return (200, versions) }
        if path.contains("/tasks") { return (200, tasks) }
        if path.contains("/flows") { return (200, flows) }
        return (404, "{}")
    }
}

@MainActor
@Suite("WorkflowsStore")
struct WorkflowsStoreTests {
    @Test("workflows load sorted by name, scoped to the workspace")
    func loads() async throws {
        let (client, transport) = RenderClient.routed { _ in
            (200, WorkflowJSON.workflowsPage([
                WorkflowJSON.workflow(id: "wfl-b", name: "zeta"),
                WorkflowJSON.workflow(id: "wfl-a", name: "Alpha"),
            ]))
        }
        let store = WorkflowsStore(client: client, ownerID: Fixtures.ownerID)

        await store.load()

        #expect(store.hasLoaded && store.errorMessage == nil)
        #expect(store.sortedWorkflows.map(\.name) == ["Alpha", "zeta"])
        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("ownerId=\(Fixtures.ownerID)"))
        #expect(!path.contains("environmentId"))
    }

    @Test("the summary reads the build config, and empty optional strings count as absent")
    func summaryFields() async throws {
        let (client, _) = RenderClient.routed { _ in
            (200, WorkflowJSON.workflowsPage([WorkflowJSON.workflow(slug: nil, defaultVersionID: nil)]))
        }
        let store = WorkflowsStore(client: client, ownerID: Fixtures.ownerID)

        await store.load()

        let workflow = try #require(store.workflows.first)
        #expect(workflow.repoDisplay == "github.com/example/sample")
        #expect(workflow.branch == "main")
        #expect(workflow.rootDir == nil)  // "" in the response
        #expect(workflow.runtime == "Python")
        #expect(workflow.region == "Oregon")
        #expect(workflow.slug == "sample")  // falls back to the name
        #expect(workflow.defaultVersionID == nil)
    }

    @Test("a workspace with no workflows loads as empty, though Render answers null")
    func emptyWorkspace() async {
        let (client, _) = RenderClient.routed { _ in (200, "null") }
        let store = WorkflowsStore(client: client, ownerID: Fixtures.ownerID)

        await store.load()

        #expect(store.hasLoaded && store.workflows.isEmpty && store.errorMessage == nil)
    }

    @Test("a failed reload keeps the workflows already shown")
    func failureKeepsList() async {
        let fail = LockedFlag()
        let (client, _) = RenderClient.routed { _ in
            fail.value
                ? (500, #"{"message":"boom"}"#)
                : (200, WorkflowJSON.workflowsPage([WorkflowJSON.workflow()]))
        }
        let store = WorkflowsStore(client: client, ownerID: Fixtures.ownerID)

        await store.load()
        fail.value = true
        await store.load()

        #expect(store.workflows.count == 1)
        #expect(store.errorMessage != nil)
    }
}

@MainActor
@Suite("WorkflowDetailStore")
struct WorkflowDetailStoreTests {
    private func workflow(defaultVersionID: String?) async throws -> WorkflowSummary {
        let (client, _) = RenderClient.routed { _ in
            (200, WorkflowJSON.workflowsPage([WorkflowJSON.workflow(defaultVersionID: defaultVersionID)]))
        }
        let list = WorkflowsStore(client: client, ownerID: Fixtures.ownerID)
        await list.load()
        return try #require(list.workflows.first)
    }

    @Test("tasks and flows come from the default version only, not once per build")
    func defaultVersion() async throws {
        let (client, transport) = RenderClient.routed { WorkflowJSON.route(for: $0) }
        let store = WorkflowDetailStore(client: client, workflow: try await workflow(defaultVersionID: "wfv-1"))

        await store.load()

        #expect(store.errorMessage == nil && store.hasLoaded)
        #expect(store.currentVersion?.id == "wfv-1")
        #expect(store.tasks.map(\.id) == ["tsk-1b", "tsk-1a"])  // slow, square
        #expect(store.flows.map(\.id) == ["flw-1"])
        // Every list is filtered by this workflow.
        // The versions list spells the parameter `workflowID`, as the spec does; the live API accepts it.
        #expect(transport.requests.allSatisfy {
            $0.path?.lowercased().contains("workflowid=wfl-1") == true
        })
    }

    @Test("versions are newest first, and with no default the newest ready one is current")
    func newestReadyFallback() async throws {
        let (client, _) = RenderClient.routed { WorkflowJSON.route(for: $0) }
        let store = WorkflowDetailStore(client: client, workflow: try await workflow(defaultVersionID: nil))

        await store.load()

        #expect(store.versions.map(\.id) == ["wfv-3", "wfv-2", "wfv-1"])
        #expect(store.versions.first?.status == .buildFailed)
        // The failed build is newest, but registered nothing runnable, so v2 is current.
        #expect(store.currentVersion?.id == "wfv-2")
        #expect(store.tasks.map(\.name) == ["fail", "slow", "square"])
    }

    @Test("with no version to pick by, duplicate names across builds are collapsed")
    func noVersionCollapses() async throws {
        let (client, _) = RenderClient.routed { path in
            path.contains("/workflowversions") ? (200, "[]") : WorkflowJSON.route(for: path)
        }
        let store = WorkflowDetailStore(client: client, workflow: try await workflow(defaultVersionID: nil))

        await store.load()

        #expect(store.currentVersion == nil)
        #expect(store.tasks.map(\.name) == ["fail", "slow", "square"])
        #expect(store.flows.map(\.name) == ["describe"])
    }

    @Test("one failing list fails the load and keeps what was shown")
    func failureKeepsDetail() async throws {
        let fail = LockedFlag()
        let (client, _) = RenderClient.routed { path in
            fail.value && path.contains("/flows") ? (500, #"{"message":"boom"}"#) : WorkflowJSON.route(for: path)
        }
        let store = WorkflowDetailStore(client: client, workflow: try await workflow(defaultVersionID: "wfv-2"))

        await store.load()
        fail.value = true
        await store.load()

        #expect(store.errorMessage != nil)
        #expect(store.tasks.count == 3)
        #expect(store.flows.count == 1)
    }
}
