import Foundation
import Observation
import RenderAPI

/// Starts a deploy from a config screen, so a saved change can be made live where it was made.
///
/// Phase 5a established, by measurement rather than assumption, that an API config write does **not**
/// deploy: `PUT /services/{id}/env-vars/{key}` changes the service's configuration immediately but
/// starts no deploy, so the running instances keep the old value. The banner says so — and this is
/// what it says it *with*. "I changed a variable" is almost always followed by "…and now I need it
/// live", and the alternative is backing out of two screens to find the action menu.
///
/// It deliberately deploys the way the detail screen's plain **Deploy** does — latest commit or
/// image, cache intact. A cache-clearing build is a debugging tool, not the thing someone wants
/// after editing a variable, and offering both in a banner would make the quick path a decision.
@MainActor
@Observable
final class ConfigDeployer {
    /// Named in the confirmation, the same as every other action that touches a live service.
    let serviceName: String
    /// Commit- or image-backed, which decides the wording. Telling someone on an image-backed
    /// service that we'll build the latest commit is simply wrong.
    let source: ServiceAction.Source
    private(set) var isDeploying = false

    private let client: RenderClient
    private let serviceID: String

    init(client: RenderClient, serviceID: String, serviceName: String, source: ServiceAction.Source) {
        self.client = client
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.source = source
    }

    /// `nil` for a service that has no deploy of its own — a cron job runs, it doesn't deploy, and
    /// its config screens shouldn't offer a button that can't be pressed.
    static func make(client: RenderClient, service: ServiceDetailModel) -> ConfigDeployer? {
        guard service.type != .cronJob else { return nil }
        return ConfigDeployer(
            client: client,
            serviceID: service.id,
            serviceName: service.name,
            source: service.details.runtime == .image ? .image : .commit
        )
    }

    /// The action this deployer performs. Sharing the `ServiceAction` case rather than re-writing
    /// the copy means the confirmation here and the one in the detail screen's menu can't drift.
    var action: ServiceAction { .deploy(clearCache: false, source: source) }

    /// Deploys, and returns the banner to show next — or `nil` when a deploy is already in flight,
    /// which leaves the current banner alone rather than replacing it with a non-event.
    func deploy() async -> ConfigActionResult? {
        guard !isDeploying else { return nil }
        isDeploying = true
        defer { isDeploying = false }

        do {
            try await DeploysStore.createDeploy(client: client, serviceID: serviceID, clearCache: false)
            // "Started", not "deployed": the endpoint is asynchronous, and a build takes minutes.
            // Claiming the change is live the moment the request returns would repeat, one step
            // later, exactly the mistake this whole affordance exists to correct.
            return .success("Deploy started. The change is live when it finishes.")
        } catch {
            return .failure(error)
        }
    }
}
