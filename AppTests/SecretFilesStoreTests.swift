import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("SecretFilesStore")
struct SecretFilesStoreTests {
    private func store(bodies: [String], status: Int = 200, pageSize: Int = 100) -> (SecretFilesStore, StubTransport) {
        let (client, transport) = RenderClient.stubbed(jsonBodies: bodies, status: status)
        return (SecretFilesStore(client: client, serviceID: "srv-1", pageSize: pageSize), transport)
    }

    @Test("files load, sorted by name")
    func loadsSorted() async {
        let (store, _) = store(bodies: [
            Fixtures.secretFilesPage([(name: "z.json", content: "{}"), (name: "a.pem", content: "KEY")])
        ])

        await store.load()

        #expect(store.sortedFiles.map(\.name) == ["a.pem", "z.json"])
    }

    @Test("saving PUTs one file by name, with the contents in the body")
    func savePutsOneFile() async throws {
        // Same reasoning as env vars: the whole-list PUT would delete any file added elsewhere.
        let recorder = BodyRecorder()
        let store = SecretFilesStore(
            // Render answers 200 with an env-var-shaped body — see the next test.
            client: recorder.client(answering: #"{"key":"creds.json","value":"{}"}"#, status: 200),
            serviceID: "srv-1"
        )

        let saved = await store.save(name: "creds.json", content: #"{"a":1}"#)

        #expect(saved)
        let request = try #require(recorder.requests.first)
        #expect(request.method == .put)
        #expect(request.path == "/services/srv-1/secret-files/creds.json")
        #expect(recorder.compactBodies.first == #"{"content":"{\"a\":1}"}"#)
        #expect(store.files.map(\.name) == ["creds.json"])
    }

    @Test("the 200 Render really answers with is a success, not a failure to reach Render")
    func acceptsTheUndocumentedTwoHundred() async {
        // Measured live, 2026-08-12: `PUT /secret-files/{name}` answers **200**, not the 201 the
        // spec documents, and its body is env-var shaped — `{"key","value"}`, not a secret file.
        // Reading `.created` meant every real create threw, so a file Render had already written
        // was reported as "Couldn't reach Render", with the whole HTTP response in the banner.
        let recorder = BodyRecorder()
        let store = SecretFilesStore(
            client: recorder.client(answering: #"{"key":"a.pem","value":"SENT"}"#, status: 200),
            serviceID: "srv-1"
        )

        let saved = await store.save(name: "a.pem", content: "SENT")

        #expect(saved)
        #expect(store.actionResult?.isFailure == false)
        // The request, not the response: the reply doesn't describe the file, so it can't be
        // applied. This is the one write where Render isn't the authority on what it stored.
        #expect(store.files == [SecretFileEntry(name: "a.pem", content: "SENT")])
    }

    @Test("the documented 201 is still accepted, in case Render starts sending it")
    func stillAcceptsTheDocumentedCreated() async {
        let recorder = BodyRecorder()
        let store = SecretFilesStore(
            client: recorder.client(answering: Fixtures.secretFile(name: "a.pem", content: "SENT"), status: 201),
            serviceID: "srv-1"
        )

        let saved = await store.save(name: "a.pem", content: "SENT")

        #expect(saved)
        #expect(store.files.first?.content == "SENT")
    }

    @Test("an undocumented failure status is still a failure")
    func undocumentedFailureStillFails() async {
        // The 2xx tolerance is exactly that — tolerance for a success code, not for anything the
        // server happens to return.
        let (client, _) = RenderClient.routed { _ in (418, "{}") }
        let store = SecretFilesStore(client: client, serviceID: "srv-1")

        let saved = await store.save(name: "a.pem", content: "SENT")

        #expect(saved == false)
        #expect(store.files.isEmpty)
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("a successful write says when the change takes effect, not that it deployed")
    func successMessageDoesNotPromiseADeploy() async {
        // Same live finding as env vars: an API write deploys nothing.
        let recorder = BodyRecorder()
        let store = SecretFilesStore(
            client: recorder.client(answering: Fixtures.secretFile(name: "a.pem", content: "KEY"), status: 201),
            serviceID: "srv-1"
        )

        await store.save(name: "a.pem", content: "KEY")

        let message = store.actionResult?.message ?? ""
        #expect(message.contains("next deploy"))
        #expect(!message.localizedCaseInsensitiveContains("redeploying"))
    }

    @Test("a saved file offers a deploy, and deploying reports in the same banner")
    func offersAndStartsDeploy() async {
        // Same affordance as env vars, for the same reason: a secret file the service hasn't
        // reloaded is a file that isn't in effect.
        let (client, transport) = RenderClient.routed { path in
            path.hasSuffix("/deploys") ? (201, Fixtures.deploy()) : (201, Fixtures.secretFile(name: "a.pem", content: "KEY"))
        }
        let store = SecretFilesStore(
            client: client,
            serviceID: "srv-1",
            deployer: ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "api", source: .commit)
        )

        await store.save(name: "a.pem", content: "KEY")
        #expect(store.actionResult?.offersDeploy == true)

        await store.deployNow()
        #expect(transport.requests.last?.path == "/services/srv-1/deploys")
        #expect(store.actionResult?.message.contains("Deploy started") == true)
        #expect(store.actionResult?.offersDeploy == false)
    }

    @Test("deleting sends a DELETE and drops the file")
    func deleteRemovesFile() async throws {
        let (client, transport) = RenderClient.routed { path in
            path.contains("secret-files/a.pem")
                ? (204, "")
                : (200, Fixtures.secretFilesPage([(name: "a.pem", content: "KEY")]))
        }
        let store = SecretFilesStore(client: client, serviceID: "srv-1")
        await store.load()

        let deleted = await store.delete(name: "a.pem")

        #expect(deleted)
        #expect(store.files.isEmpty)
        #expect(try #require(transport.requests.last).method == .delete)
    }

    @Test("a failed save keeps the old contents and reports")
    func failedSaveKeepsContents() async {
        let (client, _) = RenderClient.routed { path in
            path.contains("secret-files/a.pem")
                ? (403, "{}")
                : (200, Fixtures.secretFilesPage([(name: "a.pem", content: "KEY")]))
        }
        let store = SecretFilesStore(client: client, serviceID: "srv-1")
        await store.load()

        let saved = await store.save(name: "a.pem", content: "NEW")

        #expect(saved == false)
        #expect(store.files.first?.content == "KEY")
        #expect(store.actionResult?.isFailure == true)
    }

    @Test("an empty name never reaches the network")
    func emptyNameIsRejected() async {
        let (store, transport) = store(bodies: [Fixtures.secretFile(name: "a", content: "b")])

        #expect(await store.save(name: " ", content: "x") == false)
        #expect(transport.callCount == 0)
    }

    @Test("the row summary counts lines and bytes rather than showing contents")
    func summaryHidesContents() {
        // The list never renders a secret file's contents — this is what it shows instead.
        let file = SecretFileEntry(name: "a.pem", content: "one\ntwo\nthree")
        #expect(file.summary == "3 lines · 13 bytes")
        #expect(SecretFileEntry(name: "b", content: "x").summary == "1 line · 1 byte")
        #expect(SecretFileEntry(name: "c", content: "").summary == "0 lines · 0 bytes")
    }
}
