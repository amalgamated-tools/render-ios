import Foundation
import Observation
import RenderAPI

/// One redirect or rewrite rule.
struct RouteRuleEntry: Identifiable, Hashable, Sendable {
    let id: String
    let type: Components.Schemas.RouteType
    let source: String
    let destination: String
    let priority: Int

    var isRedirect: Bool { type == .redirect }

    init(_ route: Components.Schemas.Route) {
        self.id = route.id
        self.type = route._type
        self.source = route.source
        self.destination = route.destination
        self.priority = route.priority
    }
}

/// Reads and writes a service's redirect/rewrite rules.
///
/// **Priority is the feature, not a detail.** Rules are evaluated in priority order and the first match
/// wins, so a list in any other order would misrepresent what the service does — and reordering is the
/// main reason to open this screen after the rules exist. `PATCH /routes/{id}` carries `priority` and
/// nothing else, which is exactly the one field worth changing in place.
///
/// Editing a rule's source or destination is not offered, for the same reason a header rule can't be
/// edited: there is no per-rule write for those fields, and a delete-plus-add that fails in the middle
/// leaves a service with a rule missing.
///
/// One spec oddity, handled rather than trusted: the `PATCH` response body is
/// `{"headers": route}` — a route under a key called `headers`, which is a copy-paste slip in the spec —
/// and the field is optional. So a reorder reads it when it's there and re-reads the list when it isn't.
@MainActor
@Observable
final class RouteRulesStore {
    private(set) var rules: [RouteRuleEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

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

    /// Evaluation order: lowest priority number first, which is the order the service applies them in.
    var sortedRules: [RouteRuleEntry] {
        rules.sorted { $0.priority < $1.priority }
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

    /// Adds a rule at the end of the evaluation order.
    ///
    /// Appending rather than inserting: a new rule that silently took precedence over the existing ones
    /// could shadow all of them, and the list is where precedence gets adjusted deliberately.
    @discardableResult
    func add(type: Components.Schemas.RouteType, source: String, destination: String) async -> Bool {
        let source = source.trimmingCharacters(in: .whitespaces)
        let destination = destination.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, !destination.isEmpty, writeInFlight == nil else { return false }

        writeInFlight = source
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let created = try await client.api.addRoute(
                path: .init(serviceId: serviceID),
                body: .json(
                    .init(
                        _type: type,
                        source: source,
                        destination: destination,
                        priority: (rules.map(\.priority).max() ?? 0) + 1
                    )
                )
            ).created.body.json
            apply(RouteRuleEntry(created))
            actionResult = .success(
                "\(type == .redirect ? "Redirect" : "Rewrite") added. \(ConfigScope.service.takesEffectNote)",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Moves a rule up or down the evaluation order by swapping priorities with its neighbour.
    ///
    /// Two writes, not one: `PATCH` sets one rule's priority, so a swap needs both — and doing only the
    /// first would leave two rules claiming the same priority. If the second fails, the list is reloaded
    /// so what's on screen is what Render holds rather than the half-applied order.
    @discardableResult
    func move(_ rule: RouteRuleEntry, direction: MoveDirection) async -> Bool {
        guard writeInFlight == nil else { return false }
        let ordered = sortedRules
        guard let index = ordered.firstIndex(of: rule) else { return false }
        let neighbourIndex = direction == .up ? index - 1 : index + 1
        guard ordered.indices.contains(neighbourIndex) else { return false }
        let neighbour = ordered[neighbourIndex]

        writeInFlight = rule.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await patchPriority(of: rule, to: neighbour.priority)
            try await patchPriority(of: neighbour, to: rule.priority)
            actionResult = .success(
                "Order updated. \(ConfigScope.service.takesEffectNote)",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            // The swap may be half-applied, so stop guessing and ask.
            await load()
            return false
        }
    }

    @discardableResult
    func delete(_ rule: RouteRuleEntry) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = rule.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await client.api.deleteRoute(
                path: .init(serviceId: serviceID, routeId: rule.id)
            ).expectSuccess()
            rules.removeAll { $0.id == rule.id }
            actionResult = .success(
                "Rule removed. \(ConfigScope.service.takesEffectNote)",
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

    enum MoveDirection: Sendable {
        case up
        case down
    }

    private func patchPriority(of rule: RouteRuleEntry, to priority: Int) async throws {
        let updated = try await client.api.patchRoute(
            path: .init(serviceId: serviceID, routeId: rule.id),
            body: .json(.init(priority: priority))
        ).ok.body.json.headers
        if let updated {
            apply(RouteRuleEntry(updated))
        } else if let index = rules.firstIndex(of: rule) {
            // No echo to apply, so record what was asked for; a failure would have thrown.
            rules[index] = RouteRuleEntry(
                .init(id: rule.id, _type: rule.type, source: rule.source, destination: rule.destination, priority: priority)
            )
        }
    }

    private func apply(_ rule: RouteRuleEntry) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
        } else {
            rules.append(rule)
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.RouteWithCursor, RouteRuleEntry> {
        let client = client
        let serviceID = serviceID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listRoutes(
                    path: .init(serviceId: serviceID),
                    query: .init(cursor: cursor, limit: limit)
                )
                .ok.body.json
        } unwrap: { envelope in
            (RouteRuleEntry(envelope.route), envelope.cursor)
        }
    }
}
