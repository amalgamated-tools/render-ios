import Foundation
import RenderAPI
import Testing

@testable import RenderiOS

/// Which charts a service gets. Worth testing because it's the one piece of Phase 4 that encodes a
/// claim about Render rather than about the code: that a static site has no CPU, that a worker serves
/// no HTTP. If a claim is wrong, this is where it's written down and where it changes.
@MainActor
@Suite("Metrics catalog")
struct MetricsCatalogTests {
    private func service(type: String, diskSizeGB: Int? = nil) throws -> ServiceDetailModel {
        let json = Fixtures.serviceJSON(
            type: type,
            details: Fixtures.serviceDetailsJSON(for: type, diskSizeGB: diskSizeGB)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ServiceDetailModel(
            try decoder.decode(Components.Schemas.Service.self, from: Data(json.utf8))
        )
    }

    private func chartIDs(for type: String, diskSizeGB: Int? = nil) throws -> [String] {
        MetricsCatalog.charts(for: try service(type: type, diskSizeGB: diskSizeGB)).map(\.id)
    }

    @Test("a web service gets the full set, with bandwidth split by source")
    func webService() throws {
        #expect(try chartIDs(for: "web_service") == [
            "cpu", "memory", "instance-count", "http-requests", "http-latency", "bandwidth-sources",
        ])
    }

    @Test("a private service gets bandwidth too")
    func privateService() throws {
        // No public traffic, but calls out through NAT are still egress — seen live on a private
        // service with no HTTP traffic and 135 MB of NAT.
        #expect(try chartIDs(for: "private_service") == [
            "cpu", "memory", "instance-count", "http-requests", "http-latency", "bandwidth-sources",
        ])
    }

    @Test("a background worker gets compute and outbound bandwidth")
    func backgroundWorker() throws {
        #expect(try chartIDs(for: "background_worker") == ["cpu", "memory", "instance-count", "bandwidth-sources"])
    }

    @Test("a cron job gets no instance count")
    func cronJob() throws {
        // Its container exists only during a run, so an instance count over time would be a chart of
        // ones and gaps.
        #expect(try chartIDs(for: "cron_job") == ["cpu", "memory"])
    }

    @Test("a static site gets bandwidth only")
    func staticSite() throws {
        // Served from the CDN: there is no instance to measure, so CPU and memory aren't "no data",
        // they're not applicable.
        #expect(try chartIDs(for: "static_site") == ["bandwidth"])
    }

    @Test("the disk chart appears only when a disk is attached")
    func diskChart() throws {
        #expect(try chartIDs(for: "web_service", diskSizeGB: 10).contains("disk"))
        #expect(try !chartIDs(for: "web_service").contains("disk"))
        // A static site can't have a disk, and adding one to the fixture mustn't conjure the chart.
        #expect(try !chartIDs(for: "static_site", diskSizeGB: 10).contains("disk"))
    }

    @Test("limits and targets are reference lines, never measurements")
    func referenceRoles() {
        // The headline reads measurements only; a limit promoted to a measurement would show the
        // plan's ceiling as if it were the current usage.
        let references = (MetricsCatalog.cpu.series + MetricsCatalog.memory.series)
            .filter { $0.role == .reference }
            .map(\.name)
        #expect(references == ["Limit", "Autoscaling target", "Limit", "Autoscaling target"])
        #expect(MetricsCatalog.disk.series.last?.role == .reference)
    }

    @Test("latency asks for three distinct quantiles")
    func latencyQuantiles() {
        let ids = MetricsCatalog.httpLatency.series.map(\.id)
        #expect(Set(ids).count == 3)
        #expect(MetricsCatalog.httpLatency.series.map(\.name) == ["p50", "p95", "p99"])
    }

    // MARK: - Datastores

    private func postgres(
        diskSizeGB: Int? = nil,
        highAvailability: Bool = false,
        readReplicaNames: [String] = [],
        primaryPostgresID: String? = nil
    ) throws -> PostgresDetailModel {
        let json = Fixtures.postgresJSON(
            role: primaryPostgresID == nil ? "primary" : "replica",
            highAvailability: highAvailability,
            diskSizeGB: diskSizeGB,
            readReplicaNames: readReplicaNames,
            primaryPostgresID: primaryPostgresID
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return PostgresDetailModel(
            try decoder.decode(Components.Schemas.PostgresDetail.self, from: Data(json.utf8))
        )
    }

    @Test("postgres gets compute, connections, and — with a fixed disk — disk")
    func postgresCharts() throws {
        let withDisk = MetricsCatalog.charts(forPostgres: try postgres(diskSizeGB: 10)).map(\.id)
        #expect(withDisk == ["cpu", "memory", "active-connections", "disk"])

        // Flexible plans report no diskSizeGB, so there is no capacity to chart against.
        let withoutDisk = MetricsCatalog.charts(forPostgres: try postgres(diskSizeGB: nil)).map(\.id)
        #expect(withoutDisk == ["cpu", "memory", "active-connections"])
    }

    @Test("replication lag appears only where something replicates")
    func replicationLag() throws {
        // A lone primary always reports an empty series; the chart would only ever say "No data".
        #expect(try !MetricsCatalog.charts(forPostgres: postgres()).map(\.id).contains("replication-lag"))

        for database in [
            try postgres(readReplicaNames: ["db-replica"]),
            try postgres(highAvailability: true),
            try postgres(primaryPostgresID: "dpg-primary"),
        ] {
            #expect(MetricsCatalog.charts(forPostgres: database).map(\.id)
                == ["cpu", "memory", "active-connections", "replication-lag"])
        }
    }

    @Test("only compute charts follow the instance filter, only HTTP charts the host and path")
    func filterReach() {
        let instance = [MetricsCatalog.cpu, MetricsCatalog.memory]
        let http = [MetricsCatalog.httpRequests, MetricsCatalog.httpLatency]
        let neither = [MetricsCatalog.instanceCount, MetricsCatalog.bandwidthBySource, MetricsCatalog.disk]

        #expect(instance.allSatisfy { $0.followsInstanceFilter && !$0.followsHTTPFilters })
        #expect(http.allSatisfy { $0.followsHTTPFilters && !$0.followsInstanceFilter })
        #expect(neither.allSatisfy { !$0.followsInstanceFilter && !$0.followsHTTPFilters })
    }

    @Test("key value gets compute and connections")
    func keyValueCharts() throws {
        let json = Fixtures.keyValueJSON(includeDashboardURL: false)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let instance = KeyValueDetailModel(
            try decoder.decode(Components.Schemas.KeyValueDetail.self, from: Data(json.utf8))
        )
        #expect(MetricsCatalog.charts(forKeyValue: instance).map(\.id) == ["cpu", "memory", "active-connections"])
    }
}
