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
            // 201 for both create and update — see the next test.
            client: recorder.client(answering: Fixtures.secretFile(name: "creds.json", content: "{}"), status: 201),
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

    @Test("a 201 response is what a create answers with, and it's applied like an update")
    func appliesCreatedResponse() async {
        // `PUT /secret-files/{name}` answers 201 for both create and update — the store reads
        // `.created`, so a plain 200 would be an unexpected status and a thrown error.
        let recorder = BodyRecorder()
        let store = SecretFilesStore(
            client: recorder.client(answering: Fixtures.secretFile(name: "a.pem", content: "STORED"), status: 201),
            serviceID: "srv-1"
        )

        let saved = await store.save(name: "a.pem", content: "SENT")

        #expect(saved)
        #expect(store.files.first?.content == "STORED")
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
