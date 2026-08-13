import Foundation
import Observation
import RenderAPI

/// One env group: its name, its linked services, and the way into its variables and secret files.
///
/// Most writes here answer with the **whole group**, which is a gift the service-scoped endpoints don't
/// give: a rename and a link both return the updated `envGroup`, so the screen never has to guess at its
/// new state or re-fetch to find out. The exception is the unlink, which answers with no body at all — so
/// that case, and only that case, edits the list in place. It also answers `200` where the spec says
/// `204`; see ``NoContentWrite`` for what that cost before the live pass caught it.
@MainActor
@Observable
final class EnvGroupDetailStore {
    private(set) var group: EnvGroupSummary
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    private let client: RenderClient
    /// Called with the updated group so the list behind this screen stays honest without a reload.
    private let onChange: (EnvGroupSummary) -> Void

    init(
        client: RenderClient,
        group: EnvGroupSummary,
        onChange: @escaping (EnvGroupSummary) -> Void = { _ in }
    ) {
        self.client = client
        self.group = group
        self.onChange = onChange
    }

    /// The variables screen for this group — the same screen a service gets, over a different backend.
    var envVarBackend: EnvVarBackend {
        .envGroup(client: client, groupID: group.id, linkedServiceCount: group.linkedServiceCount)
    }

    var secretFileBackend: SecretFileBackend {
        .envGroup(client: client, groupID: group.id, linkedServiceCount: group.linkedServiceCount)
    }

    var sortedLinks: [EnvGroupServiceLink] {
        group.links.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Reading

    /// Re-reads the group, so returning from the variables screen shows a link count and an
    /// `updatedAt` that reflect what was just done there.
    func refresh() async {
        do {
            let group = try await client.api
                .retrieveEnvGroup(path: .init(envGroupId: group.id))
                .ok.body.json
            apply(EnvGroupSummary(group))
        } catch {
            // A failed refresh leaves the group as it was rather than replacing the screen with an
            // error: everything shown is still what Render last said.
            actionResult = .failure(error)
        }
    }

    // MARK: - Writing

    /// Renames the group. A group's name is its label, not its identity — Render addresses it by ID —
    /// so unlike an env var key, this really is a rename and not a delete-plus-create.
    @discardableResult
    func rename(to name: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != group.name, writeInFlight == nil else { return false }

        writeInFlight = group.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let updated = try await client.api.updateEnvGroup(
                path: .init(envGroupId: group.id),
                body: .json(.init(name: name))
            ).ok.body.json
            apply(EnvGroupSummary(updated))
            // A rename changes nothing a running service reads, so this one carries no deploy caveat.
            actionResult = .success("Renamed to \(self.group.name).")
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Links a service to this group, so it inherits every variable and file in it.
    @discardableResult
    func link(serviceID: String, serviceName: String) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = serviceID
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let updated = try await client.api.linkServiceToEnvGroup(
                path: .init(envGroupId: group.id, serviceId: serviceID)
            ).ok.body.json
            apply(EnvGroupSummary(updated))
            // One service's configuration changed, however many this group feeds — so this borrows
            // the single-service wording rather than the group's.
            actionResult = .success("\(serviceName) linked. \(ConfigScope.service.takesEffectNote)")
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Unlinks a service. The group's variables stop reaching it — which is a configuration change
    /// like any other, and therefore waits for that service's next deploy.
    @discardableResult
    func unlink(_ link: EnvGroupServiceLink) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = link.id
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            // The only group write that answers with no body, so this is the only one that has to
            // edit the list itself. It also answers **200** rather than the documented 204 — see
            // `NoContentWrite`, which is why this isn't `.noContent`.
            try await client.api.unlinkServiceFromEnvGroup(
                path: .init(envGroupId: group.id, serviceId: link.id)
            ).expectSuccess()
            apply(group.removingLink(link.id))
            actionResult = .success("\(link.name) unlinked. \(ConfigScope.service.takesEffectNote)")
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private func apply(_ group: EnvGroupSummary) {
        self.group = group
        onChange(group)
    }
}
