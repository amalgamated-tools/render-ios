import Foundation
import Observation
import RenderAPI

/// One custom domain on a service.
struct CustomDomainEntry: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let domainType: Components.Schemas.CustomDomain.DomainTypePayload
    let verificationStatus: Components.Schemas.CustomDomain.VerificationStatusPayload
    let createdAt: Date
    /// Set when this row exists to redirect to another domain — the `www` half that Render creates
    /// alongside an apex. Naming it keeps the second row from looking like a duplicate.
    let redirectForName: String

    var isVerified: Bool { verificationStatus == .verified }
    var isRedirect: Bool { !redirectForName.isEmpty }

    init(_ domain: Components.Schemas.CustomDomain) {
        self.id = domain.id
        self.name = domain.name
        self.domainType = domain.domainType
        self.verificationStatus = domain.verificationStatus
        self.createdAt = domain.createdAt
        self.redirectForName = domain.redirectForName
    }

    /// What the user has to go and create at their DNS provider.
    ///
    /// Stated as the *kind* of record and where it points, not as a literal value: the target is the
    /// service's `onrender.com` hostname for a subdomain, and an IP for an apex — and inventing an IP
    /// here would be worse than saying nothing, since a wrong A record fails verification silently.
    var dnsInstruction: String {
        switch domainType {
        case .apex:
            "Point an A record for \(name) at Render's IP, shown in the Dashboard."
        case .subdomain:
            "Point a CNAME record for \(name) at the service's onrender.com hostname."
        }
    }
}

/// Reads and writes a service's custom domains.
///
/// Three things about this resource shaped the store, all confirmed in the spec:
/// 1. **Adding one domain can create two rows.** `POST /custom-domains` answers with an **array**:
///    adding an apex gets the apex *and* a `www` redirect for it. A store that took `.first` would
///    show half of what it just created and then contradict itself on the next refresh.
/// 2. **Verification is asynchronous and answers nothing.** `POST .../verify` returns **202 with no
///    body**, so it means "Render has started checking", not "verified". The status is re-read
///    afterwards rather than assumed, and the UI says which of those two happened.
/// 3. **Failures here are usually the user's to act on, off the phone.** A `402` means the instance
///    type doesn't include custom domains and a `409` means someone else has claimed the name —
///    neither is a retry, so both get their own sentence instead of a generic error.
@MainActor
@Observable
final class CustomDomainsStore {
    private(set) var domains: [CustomDomainEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    private let client: RenderClient
    private let serviceID: String
    private let pageSize: Int

    init(client: RenderClient, serviceID: String, pageSize: Int = 100) {
        self.client = client
        self.serviceID = serviceID
        self.pageSize = pageSize
    }

    /// Verified domains first would bury the one that needs attention, so unverified sort to the top
    /// and names order within each group.
    var sortedDomains: [CustomDomainEntry] {
        domains.sorted { left, right in
            if left.isVerified != right.isVerified { return !left.isVerified }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    var unverifiedCount: Int { domains.count { !$0.isVerified } }

    // MARK: - Reading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            domains = try await makePaginator().collect()
            errorMessage = nil
        } catch {
            // 406 and 410 get plain sentences here — see `ServiceConfigCatalog`.
            errorMessage = ServiceConfigCatalog.loadFailureMessage(error)
        }
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    // MARK: - Writing

    /// Adds a domain, applying **every** row Render answers with.
    @discardableResult
    func add(name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, writeInFlight == nil else { return false }

        writeInFlight = name
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let created = try await client.api.createCustomDomain(
                path: .init(serviceId: serviceID),
                body: .json(.init(name: name))
            ).created.body.json.map(CustomDomainEntry.init)

            for domain in created { apply(domain) }
            // Adding an apex also creates its `www` redirect, so the message counts what arrived
            // rather than describing what was asked for.
            let added = created.map(\.name).joined(separator: " and ")
            actionResult = .success("Added \(added.isEmpty ? name : added). DNS has to be set up before it verifies.")
            return true
        } catch {
            actionResult = Self.failure(error, name: name)
            return false
        }
    }

    /// Adding a domain has two failure modes that aren't errors so much as facts about the account, and
    /// both are acted on somewhere other than this screen. Render's own message for them is generic, so
    /// this says what actually has to happen.
    private static func failure(_ error: any Error, name: String) -> ConfigActionResult {
        guard case .client(let statusCode, _) = RenderError.wrapping(error) else {
            return .failure(error)
        }
        switch statusCode {
        case 402:
            return .failure(
                RenderError.client(
                    statusCode: 402,
                    message: "Custom domains need a paid instance type. Upgrade the service, then add \(name) again."
                )
            )
        case 409:
            return .failure(
                RenderError.client(
                    statusCode: 409,
                    message: "\(name) is already in use by another Render service."
                )
            )
        default:
            return .failure(error)
        }
    }

    /// Asks Render to re-check DNS for a domain.
    ///
    /// The reply is a 202 with no body: the check has been *queued*. So this re-reads the list
    /// afterwards and reports what the status actually is now, rather than claiming a verification the
    /// API never confirmed.
    @discardableResult
    func verify(_ domain: CustomDomainEntry) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = domain.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            _ = try await client.api.refreshCustomDomain(
                path: .init(serviceId: serviceID, customDomainNameOrID: domain.id)
            ).accepted
            await load()
            let current = domains.first { $0.id == domain.id }
            actionResult = .success(
                current?.isVerified == true
                    ? "\(domain.name) is verified."
                    : "Checking \(domain.name). It stays unverified until the DNS record resolves."
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    @discardableResult
    func delete(_ domain: CustomDomainEntry) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = domain.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await client.api.deleteCustomDomain(
                path: .init(serviceId: serviceID, customDomainNameOrID: domain.id)
            ).expectSuccess()
            domains.removeAll { $0.id == domain.id }
            // Unlike an env var, this one is immediate: the domain stops serving now, with no deploy
            // in between. Saying so is the point — it's the difference between a reversible edit and
            // taking a hostname off the internet.
            actionResult = .success("\(domain.name) removed. It stops serving traffic immediately.")
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    func containsName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return domains.contains { $0.name.lowercased() == name }
    }

    private func apply(_ domain: CustomDomainEntry) {
        if let index = domains.firstIndex(where: { $0.id == domain.id }) {
            domains[index] = domain
        } else {
            domains.append(domain)
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.CustomDomainWithCursor, CustomDomainEntry> {
        let client = client
        let serviceID = serviceID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listCustomDomains(
                    path: .init(serviceId: serviceID),
                    query: .init(cursor: cursor, limit: limit)
                )
                .ok.body.json
        } unwrap: { envelope in
            (CustomDomainEntry(envelope.customDomain), envelope.cursor)
        }
    }
}
