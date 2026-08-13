import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("CustomDomainsStore")
struct CustomDomainsStoreTests {
    @Test("adding an apex applies both rows Render creates, not just the first")
    func apexAddAppliesEveryReturnedRow() async {
        // `POST /custom-domains` answers with an **array**: the apex plus the www redirect Render makes
        // alongside it. Taking `.first` would show half of what was just created and then disagree with
        // itself on the next refresh.
        let (client, _) = RenderClient.routed { _ in
            (201, Fixtures.customDomainsCreated([
                Fixtures.customDomain(id: "dom-1", name: "example.com", domainType: "apex"),
                Fixtures.customDomain(id: "dom-2", name: "www.example.com", redirectForName: "example.com"),
            ]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")

        let added = await store.add(name: "example.com")

        #expect(added)
        #expect(store.domains.map(\.name).sorted() == ["example.com", "www.example.com"])
        #expect(store.actionResult?.message.contains("www.example.com") == true)
    }

    @Test("the www row says what it is, so it doesn't read as a stray duplicate")
    func redirectRowIsLabelled() async {
        let (client, _) = RenderClient.routed { _ in
            (200, Fixtures.customDomainsPage([
                Fixtures.customDomain(id: "dom-2", name: "www.example.com", redirectForName: "example.com")
            ]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")

        await store.load()

        #expect(store.domains.first?.isRedirect == true)
        #expect(store.domains.first?.redirectForName == "example.com")
    }

    @Test("a name is lower-cased and trimmed before it becomes a domain")
    func normalisesName() async throws {
        let recorder = BodyRecorder()
        let store = CustomDomainsStore(
            client: recorder.client(
                answering: Fixtures.customDomainsCreated([Fixtures.customDomain(id: "dom-1", name: "api.example.com")]),
                status: 201
            ),
            serviceID: "srv-1"
        )

        await store.add(name: "  API.Example.com  ")

        #expect(try #require(recorder.compactBodies.first) == #"{"name":"api.example.com"}"#)
    }

    @Test("unverified domains sort above verified ones")
    func unverifiedFirst() async {
        // The only reason to open this screen from a phone is the domain that *isn't* working.
        let (client, _) = RenderClient.routed { _ in
            (200, Fixtures.customDomainsPage([
                Fixtures.customDomain(id: "dom-1", name: "a.example.com", verificationStatus: "verified"),
                Fixtures.customDomain(id: "dom-2", name: "z.example.com", verificationStatus: "unverified"),
            ]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")

        await store.load()

        #expect(store.sortedDomains.map(\.name) == ["z.example.com", "a.example.com"])
        #expect(store.unverifiedCount == 1)
    }

    @Test("verify re-reads the status instead of claiming one, because 202 says nothing")
    func verifyRereadsStatus() async throws {
        // `POST .../verify` is a 202 with no body — the check has been queued, not passed. Reporting
        // "verified" off the back of it would be inventing the outcome.
        let (client, transport) = RenderClient.routed { path in
            if path.hasSuffix("/verify") { return (202, "") }
            return (200, Fixtures.customDomainsPage([
                Fixtures.customDomain(id: "dom-1", name: "api.example.com", verificationStatus: "unverified")
            ]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")
        await store.load()

        await store.verify(try #require(store.domains.first))

        // The verify POST, then a re-read of the list.
        #expect(transport.requests.map(\.path).contains { $0?.hasSuffix("/verify") == true })
        let message = try #require(store.actionResult?.message)
        #expect(message.contains("Checking"))
        #expect(!message.contains("is verified"))
    }

    @Test("verify says so when the re-read shows the domain has passed")
    func verifyReportsSuccess() async throws {
        let attempts = Counter()
        let (client, _) = RenderClient.routed { path in
            if path.hasSuffix("/verify") { return (202, "") }
            // First load unverified, the post-verify re-read verified.
            let status = attempts.next() == 1 ? "unverified" : "verified"
            return (200, Fixtures.customDomainsPage([
                Fixtures.customDomain(id: "dom-1", name: "api.example.com", verificationStatus: status)
            ]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")
        await store.load()

        await store.verify(try #require(store.domains.first))

        #expect(store.actionResult?.message == "api.example.com is verified.")
    }

    @Test("a 402 explains that custom domains need a paid instance type")
    func paymentRequiredCopy() async {
        // Not a retry and not a bug: a fact about the account, actioned somewhere other than this phone.
        let (client, _) = RenderClient.routed { _ in (402, "{}") }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")

        await store.add(name: "api.example.com")

        let message = store.actionResult?.message ?? ""
        #expect(store.actionResult?.isFailure == true)
        #expect(message.contains("paid instance type"))
    }

    @Test("a 409 names the real problem: someone else has the domain")
    func conflictCopy() async {
        let (client, _) = RenderClient.routed { _ in (409, "{}") }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")

        await store.add(name: "api.example.com")

        #expect(store.actionResult?.message.contains("already in use") == true)
    }

    @Test("deleting says the domain stops serving now, with no deploy in between")
    func deleteWordingIsImmediate() async throws {
        // Every other config write in the app waits for a deploy. This one doesn't, and saying so is
        // the difference between a reversible edit and taking a hostname off the internet.
        let (client, _) = RenderClient.routed { path in
            path.contains("/custom-domains/dom-1")
                ? (204, "")
                : (200, Fixtures.customDomainsPage([Fixtures.customDomain(id: "dom-1", name: "api.example.com")]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")
        await store.load()

        let deleted = await store.delete(try #require(store.domains.first))

        #expect(deleted)
        #expect(store.domains.isEmpty)
        #expect(store.actionResult?.message.contains("immediately") == true)
    }

    @Test("the DNS instruction matches the kind of domain")
    func dnsInstructionPerType() async {
        let (client, _) = RenderClient.routed { _ in
            (200, Fixtures.customDomainsPage([
                Fixtures.customDomain(id: "dom-1", name: "example.com", domainType: "apex"),
                Fixtures.customDomain(id: "dom-2", name: "api.example.com", domainType: "subdomain"),
            ]))
        }
        let store = CustomDomainsStore(client: client, serviceID: "srv-1")

        await store.load()

        let apex = store.domains.first { $0.name == "example.com" }
        let subdomain = store.domains.first { $0.name == "api.example.com" }
        #expect(apex?.dnsInstruction.contains("A record") == true)
        #expect(subdomain?.dnsInstruction.contains("CNAME") == true)
    }
}
