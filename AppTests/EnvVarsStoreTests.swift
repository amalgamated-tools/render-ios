import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("EnvVarsStore")
struct EnvVarsStoreTests {
    private func store(
        bodies: [String],
        status: Int = 200,
        pageSize: Int = 100
    ) -> (EnvVarsStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(jsonBodies: bodies, status: status)
        return (EnvVarsStore(client: client, serviceID: "srv-1", pageSize: pageSize), transport)
    }

    // MARK: - Reading

    @Test("the whole collection is drained, not just the first page")
    func drainsEveryPage() async throws {
        // A config screen showing *some* of the configuration would be a trap, so the store pages
        // to exhaustion rather than on scroll like the service list.
        let (store, transport) = store(
            bodies: [
                Fixtures.envVarsPage([(key: "B", value: "2"), (key: "A", value: "1")]),
                Fixtures.envVarsPage([(key: "C", value: "3")]),
            ],
            pageSize: 2
        )

        await store.load()

        #expect(transport.callCount == 2)
        #expect(store.sortedEntries.map(\.key) == ["A", "B", "C"])
        #expect(store.errorMessage == nil)
    }

    @Test("the list is sorted by key, not by the order Render returns")
    func sortsByKey() async {
        let (store, _) = store(bodies: [
            Fixtures.envVarsPage([(key: "PORT", value: "3000"), (key: "api_key", value: "x"), (key: "DATABASE_URL", value: "y")])
        ])

        await store.load()

        #expect(store.sortedEntries.map(\.key) == ["api_key", "DATABASE_URL", "PORT"])
    }

    @Test("search matches keys only — never values, which are masked on purpose")
    func searchIgnoresValues() async {
        let (store, _) = store(bodies: [
            Fixtures.envVarsPage([(key: "DATABASE_URL", value: "postgres://secret"), (key: "PORT", value: "3000")])
        ])
        await store.load()

        store.searchText = "data"
        #expect(store.visibleEntries.map(\.key) == ["DATABASE_URL"])

        // "secret" appears in a *value*. Matching it would tell the user which variable holds the
        // string they typed, which is the very thing the mask exists to prevent.
        store.searchText = "secret"
        #expect(store.visibleEntries.isEmpty)
    }

    @Test("a failed refresh reports but keeps what's on screen")
    func failedRefreshKeepsEntries() async {
        // A refresh that fails is a reason to say so, not a reason to blank a list the user may be
        // reading — which on a config screen is the difference between "no variables" and "we
        // couldn't ask".
        let attempts = Counter()
        let (client, _) = RenderClient.routed { _ in
            attempts.next() == 1 ? (200, Fixtures.envVarsPage([(key: "A", value: "1")])) : (500, "{}")
        }
        let store = EnvVarsStore(client: client, serviceID: "srv-1")

        await store.load()
        #expect(store.entries.map(\.key) == ["A"])

        await store.refresh()
        #expect(store.errorMessage != nil)
        #expect(store.entries.map(\.key) == ["A"])
    }

    // MARK: - Writing

    @Test("saving PUTs one key, and sends only that key's value")
    func savePutsOneKey() async throws {
        // Deliberately *not* the whole-list PUT the API also offers: that would delete any variable
        // added elsewhere since this screen loaded.
        let recorder = BodyRecorder()
        let store = EnvVarsStore(
            client: recorder.client(answering: Fixtures.envVar(key: "LOG_LEVEL", value: "debug")),
            serviceID: "srv-1"
        )

        let saved = await store.save(key: "LOG_LEVEL", value: "debug")

        #expect(saved)
        let request = try #require(recorder.requests.first)
        #expect(request.method == .put)
        #expect(request.path == "/services/srv-1/env-vars/LOG_LEVEL")
        #expect(recorder.compactBodies.first == #"{"value":"debug"}"#)
        #expect(store.entries == [EnvVarEntry(key: "LOG_LEVEL", value: "debug")])
    }

    @Test("the stored entry is what Render answered with, not what was sent")
    func appliesTheResponse() async {
        // Render is the authority on what it stored — echoing the request would make the screen
        // claim a value the API may have normalized or rejected in part.
        let recorder = BodyRecorder()
        let store = EnvVarsStore(
            client: recorder.client(answering: Fixtures.envVar(key: "PORT", value: "10000")),
            serviceID: "srv-1"
        )

        await store.save(key: "PORT", value: "3000")

        #expect(store.entries.first?.value == "10000")
    }

    @Test("saving an existing key replaces its row rather than duplicating it")
    func saveReplacesExistingRow() async {
        let (client, _) = RenderClient.routed { path in
            path.contains("env-vars/PORT")
                ? (200, Fixtures.envVar(key: "PORT", value: "4000"))
                : (200, Fixtures.envVarsPage([(key: "PORT", value: "3000")]))
        }
        let store = EnvVarsStore(client: client, serviceID: "srv-1")
        await store.load()

        await store.save(key: "PORT", value: "4000")

        #expect(store.entries.map(\.key) == ["PORT"])
        #expect(store.entries.first?.value == "4000")
    }

    @Test("a key is trimmed before it becomes part of the URL")
    func trimsKey() async throws {
        let recorder = BodyRecorder()
        let store = EnvVarsStore(
            client: recorder.client(answering: Fixtures.envVar(key: "PORT", value: "3000")),
            serviceID: "srv-1"
        )

        await store.save(key: "  PORT  ", value: "3000")

        #expect(try #require(recorder.requests.first?.path) == "/services/srv-1/env-vars/PORT")
    }

    @Test("an empty key never reaches the network")
    func emptyKeyIsRejected() async {
        let (store, transport) = store(bodies: [Fixtures.envVar(key: "x", value: "y")])

        let saved = await store.save(key: "   ", value: "value")

        #expect(saved == false)
        #expect(transport.callCount == 0)
    }

    @Test("a failed save reports, changes nothing, and says so to its caller")
    func failedSaveKeepsState() async {
        let (client, _) = RenderClient.routed { path in
            path.contains("env-vars/PORT") ? (403, "{}") : (200, Fixtures.envVarsPage([(key: "PORT", value: "3000")]))
        }
        let store = EnvVarsStore(client: client, serviceID: "srv-1")
        await store.load()

        let saved = await store.save(key: "PORT", value: "4000")

        // `false` is what keeps the editor sheet open with the user's typing intact.
        #expect(saved == false)
        #expect(store.entries.first?.value == "3000")
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("a successful write says when the change takes effect, not that it deployed")
    func successMessageDoesNotPromiseADeploy() async {
        // Found live: an env var written through the API changes the configuration but starts no
        // deploy — no deploy row, no deploy event — unlike the same edit made in the dashboard. The
        // banner used to say "Render is redeploying the service", which would have someone believe a
        // fix was live when the running instances still held the old value.
        let recorder = BodyRecorder()
        let store = EnvVarsStore(
            client: recorder.client(answering: Fixtures.envVar(key: "PORT", value: "3000")),
            serviceID: "srv-1"
        )

        await store.save(key: "PORT", value: "3000")

        let message = store.actionResult?.message ?? ""
        #expect(message.contains("next deploy"))
        #expect(!message.localizedCaseInsensitiveContains("redeploying"))
    }

    @Test("a successful write offers a deploy, which is what makes it live")
    func successOffersDeploy() async {
        // The banner is where "saved but not running" gets resolved: the change is one tap from
        // live, instead of two screens back at the action menu.
        let recorder = BodyRecorder()
        let client = recorder.client(answering: Fixtures.envVar(key: "PORT", value: "3000"))
        let store = EnvVarsStore(
            client: client,
            serviceID: "srv-1",
            deployer: ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "api", source: .commit)
        )

        await store.save(key: "PORT", value: "3000")

        #expect(store.actionResult?.offersDeploy == true)
    }

    @Test("a service that can't be deployed is never offered a deploy")
    func noDeployerNoOffer() async {
        // A cron job runs, it doesn't deploy — its banner has to stay a report.
        let recorder = BodyRecorder()
        let store = EnvVarsStore(
            client: recorder.client(answering: Fixtures.envVar(key: "PORT", value: "3000")),
            serviceID: "srv-1"
        )

        await store.save(key: "PORT", value: "3000")

        #expect(store.actionResult?.isFailure == false)
        #expect(store.actionResult?.offersDeploy == false)
    }

    @Test("a failed write offers no deploy — there's nothing to make live")
    func failedWriteOffersNoDeploy() async {
        let (client, _) = RenderClient.routed { _ in (403, "{}") }
        let store = EnvVarsStore(
            client: client,
            serviceID: "srv-1",
            deployer: ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "api", source: .commit)
        )

        await store.save(key: "PORT", value: "3000")

        #expect(store.actionResult?.isFailure == true)
        #expect(store.actionResult?.offersDeploy == false)
    }

    @Test("deploying from the banner replaces it with the deploy's own outcome")
    func deployNowReportsInTheBanner() async {
        let (client, transport) = RenderClient.routed { path in
            path.hasSuffix("/deploys") ? (201, Fixtures.deploy()) : (200, Fixtures.envVar(key: "PORT", value: "3000"))
        }
        let store = EnvVarsStore(
            client: client,
            serviceID: "srv-1",
            deployer: ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "api", source: .commit)
        )
        await store.save(key: "PORT", value: "3000")

        await store.deployNow()

        #expect(transport.requests.last?.path == "/services/srv-1/deploys")
        #expect(store.actionResult?.message.contains("Deploy started") == true)
        #expect(store.actionResult?.offersDeploy == false)
    }

    @Test("deleting sends a DELETE and drops the row")
    func deleteRemovesRow() async throws {
        let (client, transport) = RenderClient.routed { path in
            path.contains("env-vars/PORT") ? (204, "") : (200, Fixtures.envVarsPage([(key: "PORT", value: "3000")]))
        }
        let store = EnvVarsStore(client: client, serviceID: "srv-1")
        await store.load()

        let deleted = await store.delete(key: "PORT")

        #expect(deleted)
        #expect(store.entries.isEmpty)
        let request = try #require(transport.requests.last)
        #expect(request.method == .delete)
        #expect(request.path == "/services/srv-1/env-vars/PORT")
        #expect(store.actionResult?.isFailure == false)
    }

    @Test("a failed delete keeps the row")
    func failedDeleteKeepsRow() async {
        let (client, _) = RenderClient.routed { path in
            path.contains("env-vars/PORT") ? (500, "{}") : (200, Fixtures.envVarsPage([(key: "PORT", value: "3000")]))
        }
        let store = EnvVarsStore(client: client, serviceID: "srv-1")
        await store.load()

        let deleted = await store.delete(key: "PORT")

        #expect(deleted == false)
        #expect(store.entries.map(\.key) == ["PORT"])
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("containsKey drives the editor's overwrite warning, and ignores surrounding space")
    func containsKeyTrims() async {
        let (store, _) = store(bodies: [Fixtures.envVarsPage([(key: "PORT", value: "3000")])])
        await store.load()

        #expect(store.containsKey(" PORT "))
        #expect(!store.containsKey("PORTS"))
    }
}

/// Counts calls from inside a `@Sendable` route closure, for tests where the *same* path has to
/// answer differently on the second request.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Returns the 1-based call number.
    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// A stub that records request *bodies* as well as requests.
///
/// `RenderClient.stubbed` keeps only the requests, which is enough for read paths — but the whole
/// point of a write is what went in the body, and "the app sent the right value" is exactly the
/// assertion a config screen needs.
final class BodyRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var _bodies: [String] = []

    var requests: [HTTPRequest] { lock.withLock { _requests } }
    var bodies: [String] { lock.withLock { _bodies } }

    /// Bodies with the generator's pretty-printing removed, so a test can assert on the JSON it
    /// meant to send rather than on how many spaces the encoder used.
    var compactBodies: [String] {
        bodies.map { $0.filter { !$0.isWhitespace } }
    }

    /// - Parameters:
    ///   - json: The body every response carries.
    ///   - status: The status every response carries — 204 for the delete paths, which have no body.
    func client(answering json: String, status: Int = 200) -> RenderClient {
        client { _ in (status, json) }
    }

    /// Records bodies *and* chooses the reply by path — needed when a test has to load a list first and
    /// then assert on the body of the write that follows.
    func client(
        routing route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> RenderClient {
        let transport = StubTransport { [self] request, body, _ in
            let text = if let body { (try? await String(collecting: body, upTo: 1 << 20)) ?? "" } else { "" }
            lock.withLock {
                _requests.append(request)
                _bodies.append(text)
            }
            let answer = route(request.path ?? "")
            var response = HTTPResponse(status: .init(code: answer.status))
            response.headerFields = [.contentType: "application/json"]
            return (response, answer.body.isEmpty ? nil : HTTPBody(answer.body))
        }
        return RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            retryPolicy: .none,
            transport: transport
        )
    }
}
