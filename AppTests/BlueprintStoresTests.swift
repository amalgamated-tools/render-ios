import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Blueprints: the list, a Blueprint's details and resources, and its sync history.
@MainActor
@Suite("Blueprints")
struct BlueprintStoresTests {
    private nonisolated static func blueprintFields(id: String, name: String, status: String) -> String {
        #""id":"\#(id)","ownerId":"tea-1","name":"\#(name)","status":"\#(status)","autoSync":true,"repo":"https://github.com/acme/infra","branch":"main","path":"render.yaml","lastSync":"2026-11-21T10:00:00Z""#
    }

    private nonisolated static func listEntry(id: String, name: String, status: String = "in_sync") -> String {
        #"{"blueprint":{\#(blueprintFields(id: id, name: name, status: status))},"cursor":"c-\#(id)"}"#
    }

    private nonisolated static func detail(status: String = "in_sync", resources: String) -> String {
        #"{\#(blueprintFields(id: "exs-1", name: "infra", status: status)),"resources":\#(resources)}"#
    }

    private nonisolated static func sync(id: String, state: String, completedAt: String? = "2026-11-21T10:01:00Z") -> String {
        let completed = completedAt.map { #","completedAt":"\#($0)""# } ?? ""
        return #"{"sync":{"id":"\#(id)","commit":{"id":"0123456789abcdef"},"startedAt":"2026-11-21T10:00:00Z"\#(completed),"state":"\#(state)"},"cursor":"c-\#(id)"}"#
    }

    @Test("the list is sorted by name, and a status Render adds later still decodes")
    func listSortsAndToleratesNewStatus() async throws {
        let body = "[" + [Self.listEntry(id: "exs-2", name: "zeta", status: "archived"), Self.listEntry(id: "exs-1", name: "alpha")].joined(separator: ",") + "]"
        let (client, transport) = methodRouted { _, _ in (200, body) }
        let store = BlueprintsStore(client: client, ownerID: "tea-1")

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.blueprints.map(\.name) == ["alpha", "zeta"])
        #expect(store.blueprints.last?.status == "archived")
        #expect(BlueprintDisplay.statusName("archived") == "Archived")
        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/blueprints?"))
        #expect(path.contains("ownerId=tea-1"))
    }

    @Test("a failed refresh keeps the Blueprints already shown and reports the error")
    func failedRefreshKeepsList() async {
        let failing = LockedFlag()
        let (client, _) = methodRouted { _, _ in
            failing.value ? (500, #"{"message":"boom"}"#) : (200, "[" + Self.listEntry(id: "exs-1", name: "alpha") + "]")
        }
        let store = BlueprintsStore(client: client, ownerID: "tea-1")
        await store.load()
        failing.value = true

        await store.load()

        #expect(store.blueprints.map(\.id) == ["exs-1"])
        #expect(store.errorMessage != nil)
    }

    @Test("details, resources and syncs load together; unknown resource types still show")
    func detailLoadsResourcesAndSyncs() async throws {
        let resources = #"[{"id":"srv-1","name":"web","type":"web_service"},{"id":"dpg-1","name":"db","type":"postgres"},{"id":"red-1","name":"cache","type":"redis"},{"id":"zzz-1","name":"thing","type":"something_new"}]"#
        let syncs = "[" + [Self.sync(id: "s2", state: "running", completedAt: nil), Self.sync(id: "s1", state: "success")].joined(separator: ",") + "]"
        let (client, transport) = methodRouted { _, path in
            path.hasPrefix("/blueprints/exs-1/syncs") ? (200, syncs) : (200, Self.detail(resources: resources))
        }
        let store = BlueprintDetailStore(client: client, blueprintID: "exs-1")

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(store.syncsErrorMessage == nil)
        #expect(store.blueprint?.name == "infra")
        // Sorted by type name, then resource name.
        #expect(store.resources.map(\.id) == ["red-1", "dpg-1", "zzz-1", "srv-1"])
        #expect(store.resources.map(\.destination) == [.keyValue, .postgres, nil, .service])
        #expect(BlueprintDisplay.resourceTypeName("something_new") == "Something new")
        #expect(store.syncs.map(\.id) == ["s2", "s1"])
        #expect(store.syncs.first?.completedAt == nil)
        #expect(store.syncs.first?.shortCommit == "0123456")
        let paths = transport.requests.compactMap(\.path)
        #expect(paths.contains { $0.hasPrefix("/blueprints/exs-1/syncs") && $0.contains("limit=20") })
    }

    @Test("a sync history error doesn't hide the Blueprint")
    func syncErrorIsSeparate() async {
        let (client, _) = methodRouted { _, path in
            path.hasPrefix("/blueprints/exs-1/syncs") ? (500, #"{"message":"boom"}"#) : (200, Self.detail(resources: "[]"))
        }
        let store = BlueprintDetailStore(client: client, blueprintID: "exs-1")

        await store.load()

        #expect(store.blueprint?.name == "infra")
        #expect(store.errorMessage == nil)
        #expect(store.syncsErrorMessage != nil)
        #expect(store.hasLoadedSyncs)
    }

    @Test("a details error doesn't hide the sync history, and the list's copy stays on screen")
    func detailErrorIsSeparate() async {
        let (client, _) = methodRouted { _, path in
            path.hasPrefix("/blueprints/exs-1/syncs") ? (200, "[" + Self.sync(id: "s1", state: "error") + "]") : (404, #"{"message":"not found"}"#)
        }
        let initial = Blueprint(id: "exs-1", name: "from list", status: "in_sync", autoSync: false,
                                repo: "r", branch: "b", path: "p", lastSync: nil)
        let store = BlueprintDetailStore(client: client, blueprintID: "exs-1", initial: initial)

        await store.load()

        #expect(store.errorMessage != nil)
        #expect(store.blueprint?.name == "from list")
        #expect(store.syncs.map(\.state) == ["error"])
        #expect(store.syncsErrorMessage == nil)
    }

    @Test("repo links: https repos become owner/name, anything else is left alone")
    func repoFormatting() {
        #expect(BlueprintFormat.repoName("https://github.com/acme/infra") == "acme/infra")
        #expect(BlueprintFormat.repoName("https://gitlab.com/acme/infra.git") == "acme/infra")
        #expect(BlueprintFormat.repoName("not a url") == "not a url")
        #expect(BlueprintFormat.repoURL("https://github.com/acme/infra") != nil)
        #expect(BlueprintFormat.repoURL("git@github.com:acme/infra.git") == nil)
    }
}
