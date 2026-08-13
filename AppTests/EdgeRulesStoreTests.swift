import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("HeaderRulesStore")
struct HeaderRulesStoreTests {
    @Test("a created rule is read out of the plural key the spec wraps it in")
    func readsHeadersKey() async {
        // The 201 body is `{"headers": header}` — one header, plural key, optional field.
        let (client, _) = RenderClient.routed { _ in
            (201, Fixtures.headerCreated(id: "hdr-1", path: "/*", name: "X-Frame-Options", value: "DENY"))
        }
        let store = HeaderRulesStore(client: client, serviceID: "srv-1")

        let added = await store.add(path: "/*", name: "X-Frame-Options", value: "DENY")

        #expect(added)
        #expect(store.rules.map(\.name) == ["X-Frame-Options"])
        #expect(store.rules.first?.id == "hdr-1")
    }

    @Test("a create Render doesn't echo is re-read rather than dropped from the list")
    func fallsBackToAReload() async {
        // The echo field is optional, so an empty object is a legal reply to a write that happened.
        let (client, transport) = RenderClient.routed { path in
            // The POST has no query string; the list request does. So the suffix tells them apart.
            path.hasSuffix("/headers")
                ? (201, "{}")  // accepted, but nothing to apply
                : (200, Fixtures.headersPage([(id: "hdr-1", path: "/*", name: "X-Frame-Options", value: "DENY")]))
        }
        let store = HeaderRulesStore(client: client, serviceID: "srv-1")
        await store.load()

        let added = await store.add(path: "/*", name: "X-Frame-Options", value: "DENY")

        #expect(added)
        #expect(store.rules.count == 1)
        // Load, POST, then the reload that recovered the row.
        #expect(transport.callCount == 3)
    }

    @Test("rules group by path, then by header name")
    func sortsByPathThenName() async {
        let (client, _) = RenderClient.routed { _ in
            (200, Fixtures.headersPage([
                (id: "h1", path: "/assets/*", name: "Cache-Control", value: "max-age=31536000"),
                (id: "h2", path: "/*", name: "X-Frame-Options", value: "DENY"),
                (id: "h3", path: "/*", name: "Referrer-Policy", value: "no-referrer"),
            ]))
        }
        let store = HeaderRulesStore(client: client, serviceID: "srv-1")

        await store.load()

        #expect(store.sortedRules.map(\.id) == ["h3", "h2", "h1"])
    }

    @Test("deleting drops the row and offers the deploy that makes it real")
    func deleteOffersDeploy() async throws {
        let (client, transport) = RenderClient.routed { path in
            path.contains("/headers/hdr-1")
                ? (204, "")
                : (200, Fixtures.headersPage([(id: "hdr-1", path: "/*", name: "X-Frame-Options", value: "DENY")]))
        }
        let store = HeaderRulesStore(
            client: client,
            serviceID: "srv-1",
            deployer: ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "site", source: .commit)
        )
        await store.load()

        let deleted = await store.delete(try #require(store.rules.first))

        #expect(deleted)
        #expect(store.rules.isEmpty)
        #expect(transport.requests.last?.method == .delete)
        #expect(store.actionResult?.offersDeploy == true)
        #expect(store.actionResult?.message.contains("next deploy") == true)
    }
}

@MainActor
@Suite("RouteRulesStore")
struct RouteRulesStoreTests {
    /// `nonisolated` because the transport's route closure isn't main-actor isolated.
    private nonisolated static func page(
        _ routes: [(id: String, type: String, source: String, destination: String, priority: Int)]
    ) -> String {
        Fixtures.routesPage(routes)
    }

    @Test("rules are listed in evaluation order, whatever order Render returns them in")
    func sortsByPriority() async {
        // First match wins, so any other order describes a different service than the one running.
        let (client, _) = RenderClient.routed { _ in
            (200, Self.page([
                (id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 2),
                (id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 1),
            ]))
        }
        let store = RouteRulesStore(client: client, serviceID: "srv-1")

        await store.load()

        #expect(store.sortedRules.map(\.id) == ["rt-1", "rt-2"])
    }

    @Test("a new rule goes last, so it can't silently shadow the existing ones")
    func addAppendsAtTheEnd() async throws {
        // Inserting at the front would let one new rule shadow every existing one — and the rule you
        // just added is the one you're least sure about.
        let recorder = BodyRecorder()
        let client = recorder.client { path in
            path.hasSuffix("/routes")
                ? (201, Fixtures.route(id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 5))
                : (200, Fixtures.routesPage([(id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 4)]))
        }
        let store = RouteRulesStore(client: client, serviceID: "srv-1")
        await store.load()

        let added = await store.add(type: .rewrite, source: "/b", destination: "/index.html")

        #expect(added)
        // Priority is max + 1 over what's held: 4 → 5, the end of the evaluation order.
        #expect(try #require(recorder.compactBodies.last).contains(#""priority":5"#))
        #expect(store.sortedRules.map(\.id) == ["rt-1", "rt-2"])
    }

    @Test("reordering swaps both priorities, since PATCH only sets one")
    func moveSwapsBothPriorities() async throws {
        // Doing only the first write would leave two rules claiming the same priority, which is an
        // order Render is then free to break either way.
        let (client, transport) = RenderClient.routed { path in
            if path.contains("/routes/rt-1") {
                return (200, Fixtures.routePatched(id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 2))
            }
            if path.contains("/routes/rt-2") {
                return (200, Fixtures.routePatched(id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 1))
            }
            return (200, Self.page([
                (id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 1),
                (id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 2),
            ]))
        }
        let store = RouteRulesStore(client: client, serviceID: "srv-1")
        await store.load()

        let moved = await store.move(try #require(store.sortedRules.first), direction: .down)

        #expect(moved)
        let patches = transport.requests.filter { $0.method == .patch }
        #expect(patches.count == 2)
        // The order on screen now matches the priorities Render confirmed.
        #expect(store.sortedRules.map(\.id) == ["rt-2", "rt-1"])
    }

    @Test("the updated route is read out of the key called headers, spec slip and all")
    func readsRouteFromHeadersKey() async throws {
        // A swap is two PATCHes, so both have to be answered — leaving the second to fall through to the
        // list body would make this a test of the reload path instead.
        let (client, _) = RenderClient.routed { path in
            if path.contains("/routes/rt-1") {
                return (200, Fixtures.routePatched(id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 9))
            }
            if path.contains("/routes/rt-2") {
                return (200, Fixtures.routePatched(id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 1))
            }
            return (200, Self.page([
                (id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 1),
                (id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 9),
            ]))
        }
        let store = RouteRulesStore(client: client, serviceID: "srv-1")
        await store.load()

        await store.move(try #require(store.sortedRules.first), direction: .down)

        #expect(store.rules.first { $0.id == "rt-1" }?.priority == 9)
    }

    @Test("moving the first rule up does nothing at all")
    func moveAtEdgeIsANoOp() async throws {
        let (client, transport) = RenderClient.routed { _ in
            (200, Self.page([(id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 1)]))
        }
        let store = RouteRulesStore(client: client, serviceID: "srv-1")
        await store.load()
        let callsAfterLoad = transport.callCount

        let moved = await store.move(try #require(store.rules.first), direction: .up)

        #expect(moved == false)
        #expect(transport.callCount == callsAfterLoad)
    }

    @Test("a half-applied swap reloads rather than leaving a made-up order on screen")
    func failedSwapReloads() async throws {
        let (client, transport) = RenderClient.routed { path in
            // The first PATCH lands, the second fails.
            if path.contains("/routes/rt-1") {
                return (200, Fixtures.routePatched(id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 2))
            }
            if path.contains("/routes/rt-2") { return (500, "{}") }
            return (200, Self.page([
                (id: "rt-1", type: "redirect", source: "/a", destination: "/new", priority: 1),
                (id: "rt-2", type: "rewrite", source: "/b", destination: "/index.html", priority: 2),
            ]))
        }
        let store = RouteRulesStore(client: client, serviceID: "srv-1")
        await store.load()

        let moved = await store.move(try #require(store.sortedRules.first), direction: .down)

        #expect(moved == false)
        #expect(store.actionResult?.isFailure == true)
        // The last request is the reload, not the failed patch.
        #expect(transport.requests.last?.method == .get)
        #expect(store.sortedRules.map(\.id) == ["rt-1", "rt-2"])
    }
}

@Suite("ServiceConfigCatalog")
struct ServiceConfigCatalogTests {
    @Test("only the two publicly-served types offer custom domains")
    func customDomainsPerType() {
        #expect(ServiceConfigCatalog.hasCustomDomains(.webService))
        #expect(ServiceConfigCatalog.hasCustomDomains(.staticSite))
        // A private service is reachable only inside the private network; a worker and a cron job
        // serve no HTTP at all.
        #expect(!ServiceConfigCatalog.hasCustomDomains(.privateService))
        #expect(!ServiceConfigCatalog.hasCustomDomains(.backgroundWorker))
        #expect(!ServiceConfigCatalog.hasCustomDomains(.cronJob))
    }

    @Test("headers and redirects are a static-site feature, and nothing else's")
    func edgeRulesPerType() {
        #expect(ServiceConfigCatalog.hasEdgeRules(.staticSite))
        // Corrected by the live pass, which is the only reason this line is right: a real web service
        // answers `400 invalid service type. Only static sites have routes`.
        #expect(!ServiceConfigCatalog.hasEdgeRules(.webService))
        #expect(!ServiceConfigCatalog.hasEdgeRules(.privateService))
        #expect(!ServiceConfigCatalog.hasEdgeRules(.backgroundWorker))
        #expect(!ServiceConfigCatalog.hasEdgeRules(.cronJob))
    }

    @Test("Render's own explanation survives a 400, since it names the actual problem")
    func keepsRendersMessageOn400() {
        // "invalid service type. Only static sites have routes" is more use than anything this app
        // could invent, so the mapping must not overwrite it.
        #expect(
            ServiceConfigCatalog.loadFailureMessage(
                RenderError.client(statusCode: 400, message: "invalid service type. Only static sites have routes")
            ) == "invalid service type. Only static sites have routes"
        )
    }

    @Test("406 and 410 read as facts, not as failures to retry")
    func loadFailureMessages() {
        #expect(
            ServiceConfigCatalog.loadFailureMessage(RenderError.client(statusCode: 406, message: nil))
                == ServiceConfigCatalog.unsupportedMessage
        )
        #expect(
            ServiceConfigCatalog.loadFailureMessage(RenderError.client(statusCode: 410, message: nil))
                == "This service no longer exists."
        )
        // Anything else keeps the error's own words.
        #expect(
            ServiceConfigCatalog.loadFailureMessage(RenderError.server(statusCode: 500, message: "boom")) == "boom"
        )
    }
}
