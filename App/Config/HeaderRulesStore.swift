import Foundation
import Observation
import RenderAPI

/// One response header rule: a header added to responses for paths matching `path`.
struct HeaderRuleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let path: String
    let name: String
    let value: String

    init(_ header: Components.Schemas.Header) {
        self.id = header.id
        self.path = header.path
        self.name = header.name
        self.value = header.value
    }
}

/// Reads and writes a service's response header rules.
///
/// **Add and delete only — there is no edit, and that's the API's doing.** The only per-rule write is
/// `DELETE /headers/{id}`; changing one would mean the whole-list `PUT`, which Phase 5a ruled out as a
/// lost-update hazard, or a delete-plus-add whose failure in the middle leaves the rule simply gone.
/// Both are worse than making the user do the two steps where they can see them, which is the same
/// conclusion 5a reached about renaming an env var.
@MainActor
@Observable
final class HeaderRulesStore {
    private(set) var rules: [HeaderRuleEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    /// Starts a deploy from the banner: a header rule is service configuration like any other, so it
    /// waits for the next deploy.
    let deployer: ConfigDeployer?

    private let client: RenderClient
    private let serviceID: String
    private let pageSize: Int

    init(client: RenderClient, serviceID: String, deployer: ConfigDeployer? = nil, pageSize: Int = 100) {
        self.client = client
        self.serviceID = serviceID
        self.deployer = deployer
        self.pageSize = pageSize
    }

    /// Grouped by the path they apply to, then by header name — which is how they're reasoned about
    /// ("what does /assets get?") rather than the order Render returns them in.
    var sortedRules: [HeaderRuleEntry] {
        rules.sorted { left, right in
            if left.path != right.path {
                return left.path.localizedCaseInsensitiveCompare(right.path) == .orderedAscending
            }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
    }

    // MARK: - Reading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            rules = try await makePaginator().collect()
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

    @discardableResult
    func add(path: String, name: String, value: String) async -> Bool {
        let path = path.trimmingCharacters(in: .whitespaces)
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !name.isEmpty, writeInFlight == nil else { return false }

        writeInFlight = name
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            // The 201 body is `{"headers": header}` — one header under a plural key — and the field is
            // optional, so a rule that Render created but didn't echo is re-read rather than dropped
            // from the list.
            let created = try await client.api.addHeaders(
                path: .init(serviceId: serviceID),
                body: .json(.init(path: path, name: name, value: value))
            ).created.body.json.headers
            if let created {
                apply(HeaderRuleEntry(created))
            } else {
                await load()
            }
            actionResult = .success(
                "\(name) added for \(path). \(ConfigScope.service.takesEffectNote)",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    @discardableResult
    func delete(_ rule: HeaderRuleEntry) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = rule.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await client.api.deleteHeader(
                path: .init(serviceId: serviceID, headerId: rule.id)
            ).expectSuccess()
            rules.removeAll { $0.id == rule.id }
            actionResult = .success(
                "\(rule.name) removed. \(ConfigScope.service.takesEffectNote)",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    func deployNow() async {
        guard writeInFlight == nil, let deployer else { return }
        if let result = await deployer.deploy() {
            actionResult = result
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private func apply(_ rule: HeaderRuleEntry) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.HeaderWithCursor, HeaderRuleEntry> {
        let client = client
        let serviceID = serviceID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listHeaders(
                    path: .init(serviceId: serviceID),
                    query: .init(cursor: cursor, limit: limit)
                )
                .ok.body.json
        } unwrap: { envelope in
            (HeaderRuleEntry(envelope.header), envelope.cursor)
        }
    }
}
