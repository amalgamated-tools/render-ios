import Foundation
import Observation
import RenderAPI

/// A service's running instances and the IPs its outbound traffic leaves from.
///
/// The two halves load **independently and side by side**, each with its own error. They answer
/// different questions — "how many copies are running?" and "what do I allowlist?" — and the outbound
/// IPs endpoint declares `403` and `406` where the instances one doesn't, so one failing must not
/// blank the other.
///
/// Neither endpoint shares the query-insights rate limit: a live probe stayed inside the ordinary
/// per-key budget, so there's no throttling here.
@MainActor
@Observable
final class ServiceNetworkStore {
    struct Instance: Identifiable, Hashable, Sendable {
        let id: String
        let createdAt: Date
    }

    struct OutboundIPs: Hashable, Sendable {
        let isDedicated: Bool
        /// The dedicated IP set's ID; only present when `isDedicated`.
        let dedicatedSetID: String?
        let ips: [String]
    }

    private(set) var instances: [Instance] = []
    private(set) var instancesError: String?
    private(set) var hasLoadedInstances = false

    private(set) var outboundIPs: OutboundIPs?
    private(set) var outboundIPsError: String?

    private(set) var isLoading = false

    private let client: RenderClient
    private let serviceID: String

    init(client: RenderClient, serviceID: String) {
        self.client = client
        self.serviceID = serviceID
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        async let instancesLoad: Void = loadInstances()
        async let ipsLoad: Void = loadOutboundIPs()
        _ = await (instancesLoad, ipsLoad)
    }

    private func loadInstances() async {
        do {
            let fetched = try await client.api
                .listInstances(path: .init(serviceId: serviceID))
                .ok.body.json
            // Oldest first: the instance that has survived longest is the stable one, and a fresh
            // one at the bottom reads as "just restarted", which is the question a phone asks.
            instances = fetched
                .map { Instance(id: $0.id, createdAt: $0.createdAt) }
                .sorted { $0.createdAt < $1.createdAt }
            instancesError = nil
            hasLoadedInstances = true
        } catch {
            instancesError = Self.failureMessage(error)
        }
    }

    private func loadOutboundIPs() async {
        do {
            let fetched = try await client.api
                .retrieveServiceOutboundIps(path: .init(serviceId: serviceID))
                .ok.body.json
            outboundIPs = OutboundIPs(
                isDedicated: fetched._type == .dedicated,
                dedicatedSetID: fetched.dedicatedIpId,
                ips: fetched.ips
            )
            outboundIPsError = nil
        } catch {
            outboundIPsError = Self.failureMessage(error)
        }
    }

    /// `406` is this service type not having outbound IPs, the same meaning it has on the other
    /// per-service config endpoints; the shared catalog phrases it.
    static func failureMessage(_ error: any Error) -> String {
        ServiceConfigCatalog.loadFailureMessage(error)
    }
}
