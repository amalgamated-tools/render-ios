import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// The env group side of the config screens: same store, same views, different backend.
@MainActor
@Suite("Env group config backend")
struct EnvGroupBackendTests {
    @Test("a group's variables come out of the group payload, not a paged list")
    func loadsFromGroupDetail() async throws {
        // There is no `GET /env-groups/{id}/env-vars` to page — the group body carries them.
        let (client, transport) = RenderClient.routed { _ in
            (200, Fixtures.envGroup(envVars: [(key: "B", value: "2"), (key: "A", value: "1")]))
        }
        let store = EnvVarsStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 2)
        )

        await store.load()

        #expect(transport.callCount == 1)
        #expect(transport.requests.first?.path == "/env-groups/evg-1")
        #expect(store.sortedEntries.map(\.key) == ["A", "B"])
    }

    @Test("a group write replaces the whole set, because that's what Render answers with")
    func saveAppliesWholeGroup() async {
        // The reply is the entire group, which is strictly more than was asked about — including a
        // variable this screen had never seen. Narrowing it back to one key would throw that away.
        let (client, _) = RenderClient.routed { path in
            path.contains("/env-vars/")
                ? (200, Fixtures.envGroup(envVars: [(key: "A", value: "1"), (key: "ADDED_ELSEWHERE", value: "x")]))
                : (200, Fixtures.envGroup(envVars: [(key: "A", value: "0")]))
        }
        let store = EnvVarsStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 1)
        )
        await store.load()

        await store.save(key: "A", value: "1")

        #expect(store.sortedEntries.map(\.key) == ["A", "ADDED_ELSEWHERE"])
        #expect(store.entries.first { $0.key == "A" }?.value == "1")
    }

    @Test("a group's success message counts the services waiting on a deploy")
    func groupWordingNamesTheLinkedServices() async {
        // A group feeds several services, so "it takes effect on the next deploy" would be ambiguous
        // about *whose*. The count comes from serviceLinks, so the sentence is checkable.
        let (client, _) = RenderClient.routed { _ in (200, Fixtures.envGroup(envVars: [(key: "A", value: "1")])) }
        let store = EnvVarsStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 3)
        )

        await store.save(key: "A", value: "1")

        let message = store.actionResult?.message ?? ""
        #expect(message.contains("3 linked services"))
        // And no Deploy button: one tap can't honestly make a change live on three services.
        #expect(store.actionResult?.offersDeploy == false)
    }

    @Test("a group with one linked service says service, not services")
    func singularWording() async {
        let (client, _) = RenderClient.routed { _ in (200, Fixtures.envGroup(envVars: [(key: "A", value: "1")])) }
        let store = EnvVarsStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 1)
        )

        await store.save(key: "A", value: "1")

        #expect(store.actionResult?.message.contains("1 linked service.") == true)
    }

    @Test("a group nothing is linked to says so instead of promising a deploy")
    func noLinksNoDeployPromise() async {
        // "It takes effect on the next deploy of the 0 linked services" is nonsense, and worse, it
        // implies something is waiting to pick the change up.
        let (client, _) = RenderClient.routed { _ in (200, Fixtures.envGroup(envVars: [(key: "A", value: "1")])) }
        let store = EnvVarsStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 0)
        )

        await store.save(key: "A", value: "1")

        let message = store.actionResult?.message ?? ""
        #expect(message.contains("No services are linked"))
        #expect(!message.contains("next deploy"))
    }

    @Test("a service-scoped write still says exactly what Phase 5a settled on")
    func serviceWordingUnchanged() async {
        // The backend seam must not have moved the sentence 5a's live pass produced.
        let (client, _) = RenderClient.routed { _ in (200, Fixtures.envVar(key: "A", value: "1")) }
        let store = EnvVarsStore(client: client, serviceID: "srv-1")

        await store.save(key: "A", value: "1")

        #expect(store.actionResult?.message == "A saved. It takes effect on the next deploy.")
    }

    @Test("a group's secret files load from the same payload and write to the group path")
    func secretFilesUseTheGroupPaths() async throws {
        let (client, transport) = RenderClient.routed { path in
            path.contains("/secret-files/")
                ? (200, Fixtures.envGroup(secretFiles: [(name: "jwks.pem", content: "new")]))
                : (200, Fixtures.envGroup(secretFiles: [(name: "jwks.pem", content: "old")]))
        }
        let store = SecretFilesStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 1)
        )
        await store.load()
        #expect(store.files.first?.content == "old")

        let saved = await store.save(name: "jwks.pem", content: "new")

        #expect(saved)
        #expect(store.files.first?.content == "new")
        let request = try #require(transport.requests.last)
        #expect(request.path == "/env-groups/evg-1/secret-files/jwks.pem")
    }

    @Test("a group secret file write answering an undocumented 2xx is still a success")
    func secretFileTolerates200WithoutABody() async {
        // The service-scoped twin of this endpoint answers 200 where its spec says 201, with a body
        // describing the wrong resource. Assume the group one can do the same rather than reporting a
        // write Render performed as a failure.
        let (client, _) = RenderClient.routed { path in
            path.contains("/secret-files/") ? (204, "") : (200, Fixtures.envGroup())
        }
        let store = SecretFilesStore(
            backend: .envGroup(client: client, groupID: "evg-1", linkedServiceCount: 1)
        )

        let saved = await store.save(name: "jwks.pem", content: "content")

        #expect(saved)
        #expect(store.actionResult?.isFailure == false)
        // Nothing to read the stored value out of, so what was sent is what's shown.
        #expect(store.files.first?.content == "content")
    }
}
