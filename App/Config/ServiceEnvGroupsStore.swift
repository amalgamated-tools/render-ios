import Foundation
import Observation
import RenderAPI

/// The env groups one service inherits configuration from, and the ones it could.
///
/// **This screen exists because the API has no endpoint for the question it answers.** There is no
/// `GET /services/{id}/env-groups`; the association is recorded only in each group's `serviceLinks`.
/// So the whole workspace's groups are listed and split into linked and available. That's one request
/// for a question the dashboard answers directly, and it's the only way to ask it.
@MainActor
@Observable
final class ServiceEnvGroupsStore {
    private(set) var groups: [EnvGroupSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    private let client: RenderClient
    private let serviceID: String
    private let serviceName: String
    private let groupsStore: EnvGroupsStore

    /// Starts a deploy from the banner. Linking changes *this* service's configuration and nothing
    /// else's, so unlike a write inside a group, one tap here really can make it live.
    let deployer: ConfigDeployer?

    init(
        client: RenderClient,
        ownerID: String,
        serviceID: String,
        serviceName: String,
        deployer: ConfigDeployer? = nil
    ) {
        self.client = client
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.deployer = deployer
        self.groupsStore = EnvGroupsStore(client: client, ownerID: ownerID)
    }

    /// The groups feeding this service, which is what the screen is for.
    var linkedGroups: [EnvGroupSummary] {
        groups
            .filter { $0.links.contains { $0.id == serviceID } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Everything else in the workspace — the candidates for a link.
    var availableGroups: [EnvGroupSummary] {
        groups
            .filter { group in !group.links.contains { $0.id == serviceID } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        await groupsStore.load()
        if let message = groupsStore.errorMessage, groupsStore.groups.isEmpty {
            errorMessage = message
        } else {
            groups = groupsStore.groups
            errorMessage = groupsStore.errorMessage
        }
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    @discardableResult
    func link(_ group: EnvGroupSummary) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = group.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let updated = try await client.api.linkServiceToEnvGroup(
                path: .init(envGroupId: group.id, serviceId: serviceID)
            ).ok.body.json
            apply(EnvGroupSummary(updated))
            actionResult = .success(
                "\(group.name) linked. \(ConfigScope.service.takesEffectNote)",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    @discardableResult
    func unlink(_ group: EnvGroupSummary) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = group.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            // No body, so the link list is edited here rather than replaced by a response — and the
            // status is 200, not the documented 204. See `NoContentWrite`.
            try await client.api.unlinkServiceFromEnvGroup(
                path: .init(envGroupId: group.id, serviceId: serviceID)
            ).expectSuccess()
            apply(group.removingLink(serviceID))
            actionResult = .success(
                "\(group.name) unlinked. \(ConfigScope.service.takesEffectNote)",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Deploys the service, so an inherited variable set actually reaches the running instances.
    func deployNow() async {
        guard writeInFlight == nil, let deployer else { return }
        if let result = await deployer.deploy() {
            actionResult = result
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private func apply(_ group: EnvGroupSummary) {
        if let index = groups.firstIndex(where: { $0.id == group.id }) {
            groups[index] = group
        } else {
            groups.append(group)
        }
    }
}
