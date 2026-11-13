import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("ServiceNetworkStore")
struct ServiceNetworkStoreTests {
    private nonisolated static let instances = #"""
    [
      {"id": "srv-1-newer", "createdAt": "2026-03-02T10:00:00Z"},
      {"id": "srv-1-older", "createdAt": "2026-03-01T10:00:00Z"}
    ]
    """#
    private nonisolated static let sharedIPs = #"{"type":"shared","ips":["74.220.48.0/24","74.220.56.0/24"]}"#
    private nonisolated static let dedicatedIPs =
        #"{"type":"dedicated","dedicatedIpId":"egs-abc123","ips":["203.0.113.7"]}"#

    private func store(
        _ route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (ServiceNetworkStore, StubTransport) {
        let (client, transport) = RenderClient.routed(route: route)
        return (ServiceNetworkStore(client: client, serviceID: "srv-1"), transport)
    }

    @Test("both halves load, instances oldest first")
    func loadsBoth() async {
        let (store, _) = store { path in
            path.hasSuffix("/instances") ? (200, Self.instances) : (200, Self.sharedIPs)
        }

        await store.load()

        #expect(store.instances.map(\.id) == ["srv-1-older", "srv-1-newer"])
        #expect(store.outboundIPs?.isDedicated == false)
        #expect(store.outboundIPs?.ips == ["74.220.48.0/24", "74.220.56.0/24"])
        #expect(store.instancesError == nil && store.outboundIPsError == nil)
    }

    @Test("a dedicated IP set carries its ID")
    func dedicated() async {
        let (store, _) = store { path in
            path.hasSuffix("/instances") ? (200, "[]") : (200, Self.dedicatedIPs)
        }

        await store.load()

        #expect(store.outboundIPs?.isDedicated == true)
        #expect(store.outboundIPs?.dedicatedSetID == "egs-abc123")
        #expect(store.hasLoadedInstances && store.instances.isEmpty)
    }

    @Test("outbound IPs failing with 406 doesn't blank the instances, and says why in words")
    func ipsFailureIsIndependent() async {
        let (store, _) = store { path in
            path.hasSuffix("/instances")
                ? (200, Self.instances)
                : (406, #"{"message":"not acceptable"}"#)
        }

        await store.load()

        #expect(store.instances.count == 2)
        #expect(store.outboundIPs == nil)
        #expect(store.outboundIPsError == ServiceConfigCatalog.unsupportedMessage)
    }

    @Test("instances failing doesn't blank the outbound IPs")
    func instancesFailureIsIndependent() async {
        let (store, _) = store { path in
            path.hasSuffix("/instances")
                ? (404, #"{"message":"not found: service: srv-1"}"#)
                : (200, Self.sharedIPs)
        }

        await store.load()

        #expect(store.instancesError != nil)
        #expect(!store.hasLoadedInstances)
        #expect(store.outboundIPs?.ips.count == 2)
    }

    @Test("a failed refresh keeps what was already loaded and records the error")
    func failedRefreshKeepsData() async {
        let failing = Flag()
        let (store, _) = store { path in
            if failing.isSet { return (500, #"{"message":"boom"}"#) }
            return path.hasSuffix("/instances") ? (200, Self.instances) : (200, Self.sharedIPs)
        }

        await store.load()
        failing.set()
        await store.load()

        #expect(store.instances.count == 2)
        #expect(store.outboundIPs?.ips.count == 2)
        #expect(store.instancesError != nil && store.outboundIPsError != nil)
    }

    @Test("static sites don't get the drill-down; every other type does")
    func gate() {
        #expect(!ServiceConfigCatalog.hasInstancesAndOutboundIPs(.staticSite))
        for type in [Components.Schemas.ServiceType.webService, .privateService, .backgroundWorker, .cronJob] {
            #expect(ServiceConfigCatalog.hasInstancesAndOutboundIPs(type))
        }
    }
}

/// A thread-safe switch the route closure can read after the test flips it.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
