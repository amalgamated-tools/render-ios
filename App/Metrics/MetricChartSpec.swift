import Foundation
import RenderAPI

/// One chart: a title, and the series drawn on it.
struct MetricChartSpec: Identifiable, Hashable, Sendable {
    /// How a series is drawn, and how much it matters.
    enum Role: Hashable, Sendable {
        /// A measurement. Solid line, part of the headline value.
        case measurement
        /// A ceiling or a target — the plan's memory limit, the autoscaling CPU target. Dashed, and
        /// excluded from the headline: what matters is the reading, and the line is there to say how
        /// close it is to the edge.
        case reference
    }

    struct Series: Identifiable, Hashable, Sendable {
        let kind: MetricKind
        /// Legend name when the fetch returns a single series.
        let name: String
        let role: Role
        /// The label field that tells sibling series apart when the fetch returns several — instance
        /// ID for CPU, status code for a grouped request count. Named explicitly rather than guessed
        /// from whatever labels happen to come back, so a new label can't silently rename the legend.
        let distinguishingLabel: String?
        /// Legend names for label values Render reports in API spelling — `nat` reads as "NAT".
        /// A value missing from the map is shown as sent.
        let labelTitles: [String: String]

        var id: String { kind.id }

        init(
            _ kind: MetricKind,
            name: String,
            role: Role = .measurement,
            distinguishingLabel: String? = "instance",
            labelTitles: [String: String] = [:]
        ) {
            self.kind = kind
            self.name = name
            self.role = role
            self.distinguishingLabel = distinguishingLabel
            self.labelTitles = labelTitles
        }
    }

    /// How to reduce several measurement series to the one number in the header.
    enum Headline: Hashable, Sendable {
        /// The newest reading. Right for a rate or a level — CPU, memory, latency.
        case latest
        /// The newest readings added together. Right for a count split across series: three status
        /// codes at 10/5/1 requests is 16 requests, not 10.
        case sumOfLatest
    }

    let id: String
    let title: String
    let systemImage: String
    /// One line under the chart, when the metric needs a caveat rather than a definition.
    let footnote: String?
    let headline: Headline
    let series: [Series]

    init(
        id: String,
        title: String,
        systemImage: String,
        footnote: String? = nil,
        headline: Headline = .latest,
        series: [Series]
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.footnote = footnote
        self.headline = headline
        self.series = series
    }

    /// Every series this chart needs fetched.
    var kinds: [MetricKind] { series.map(\.kind) }

    /// Whether the metrics screen's instance filter changes this chart. Only CPU and memory accept
    /// an instance.
    var followsInstanceFilter: Bool {
        kinds.contains { [.cpu, .memory].contains($0) }
    }

    /// Whether the host and path filters change this chart. Only the HTTP endpoints accept them.
    var followsHTTPFilters: Bool {
        kinds.contains {
            switch $0 {
            case .httpRequests, .httpLatency: true
            default: false
            }
        }
    }
}

/// Which charts a resource actually has.
///
/// Driven by service type, because most of these metrics don't exist for most types: a static site
/// has no CPU (it's served from the CDN, not an instance), a background worker has no HTTP, and disk
/// metrics only mean something with a disk attached. Offering all of them everywhere would fill the
/// screen with empty axes and make "no data" ambiguous between *nothing happened* and *this doesn't
/// apply here*.
///
/// Where it's genuinely unclear whether Render collects a series — HTTP metrics for a private
/// service, which does serve requests but only inside the private network — the chart is included.
/// A chart that turns out to be empty says "No data in this range", which is a mild cost; a chart
/// wrongly withheld hides something real and the user has no way to find out.
enum MetricsCatalog {
    static func charts(for service: ServiceDetailModel) -> [MetricChartSpec] {
        var charts: [MetricChartSpec] = []

        if runsOnInstances(service.type) {
            charts.append(cpu)
            charts.append(memory)
        }
        if scalesHorizontally(service.type) {
            charts.append(instanceCount)
        }
        if servesHTTP(service.type) {
            charts.append(httpRequests)
            charts.append(httpLatency)
        }
        if hasBandwidthBySource(service.type) {
            charts.append(bandwidthBySource)
        } else if service.type == .staticSite {
            // A static site is served from the CDN, so there's nothing to split by source. The plain
            // endpoint is the one known to answer for it.
            charts.append(bandwidth)
        }
        // The disk endpoints answer for the disk attached to a service, so with no disk there is
        // nothing to ask about — unlike the cases above, this one isn't a judgement call.
        if service.details.disk != nil {
            charts.append(disk)
        }
        return charts
    }

    /// Datastore charts are a fixed set rather than type-driven: every Postgres instance has CPU,
    /// memory, and connections. Disk only exists on plans with a fixed disk — flexible plans
    /// report no `diskSizeGB`, so there is nothing to chart against.
    static func charts(forPostgres database: PostgresDetailModel) -> [MetricChartSpec] {
        var charts: [MetricChartSpec] = [cpu, memory, activeConnections]
        if hasReplication(database) {
            charts.append(replicationLag)
        }
        if database.diskSizeGB != nil {
            charts.append(disk)
        }
        return charts
    }

    static func charts(forKeyValue instance: KeyValueDetailModel) -> [MetricChartSpec] {
        [cpu, memory, activeConnections]
    }

    // MARK: - Applicability

    private static func runsOnInstances(_ type: Components.Schemas.ServiceType) -> Bool {
        type != .staticSite
    }

    private static func scalesHorizontally(_ type: Components.Schemas.ServiceType) -> Bool {
        // A cron job's container exists only while a run is in flight, so an instance count over
        // time is a chart of ones and gaps.
        type == .webService || type == .privateService || type == .backgroundWorker
    }

    private static func servesHTTP(_ type: Components.Schemas.ServiceType) -> Bool {
        type == .webService || type == .privateService
    }

    private static func hasBandwidthBySource(_ type: Components.Schemas.ServiceType) -> Bool {
        // Egress from instances. Not just public responses: a private service or a worker calling
        // out through NAT is billed bandwidth too — the live pass found a private service with 135 MB
        // of NAT traffic and no chart for it. A cron job's runs are too brief to chart.
        type == .webService || type == .privateService || type == .backgroundWorker
    }

    /// A database with something replicating from it, or one that is itself a replica. A
    /// high-availability standby is a replica too, so lag applies there. Otherwise the series is
    /// always empty, and the chart would only ever say "No data".
    private static func hasReplication(_ database: PostgresDetailModel) -> Bool {
        !database.readReplicaNames.isEmpty
            || database.isHighAvailabilityEnabled
            || database.primaryPostgresID != nil
    }

    // MARK: - The charts

    static let cpu = MetricChartSpec(
        id: "cpu",
        title: "CPU",
        systemImage: "cpu",
        series: [
            .init(.cpu, name: "Usage"),
            .init(.cpuLimit, name: "Limit", role: .reference),
            // Only present when autoscaling is on, and dropped as an empty series otherwise.
            .init(.cpuTarget, name: "Autoscaling target", role: .reference),
        ]
    )

    static let memory = MetricChartSpec(
        id: "memory",
        title: "Memory",
        systemImage: "memorychip",
        series: [
            .init(.memory, name: "Usage"),
            .init(.memoryLimit, name: "Limit", role: .reference),
            .init(.memoryTarget, name: "Autoscaling target", role: .reference),
        ]
    )

    static let instanceCount = MetricChartSpec(
        id: "instance-count",
        title: "Instances",
        systemImage: "square.stack.3d.up",
        series: [.init(.instanceCount, name: "Instances", distinguishingLabel: nil)]
    )

    static let httpRequests = MetricChartSpec(
        id: "http-requests",
        title: "HTTP Requests",
        systemImage: "arrow.left.arrow.right",
        // Grouped by status code rather than totalled, because the question at 3am is not how many
        // requests there were but how many of them failed.
        headline: .sumOfLatest,
        series: [
            .init(
                .httpRequests(aggregateBy: .statusCode),
                name: "Requests",
                distinguishingLabel: "statusCode"
            )
        ]
    )

    static let httpLatency = MetricChartSpec(
        id: "http-latency",
        title: "HTTP Latency",
        systemImage: "timer",
        footnote: "Server-side response time, excluding network transit.",
        series: [
            // Three quantiles in one chart: a p50 alone hides the tail, and a p99 alone can't say
            // whether everything is slow or a few things are.
            //
            // Each quantile can itself come back as several series — the live pass showed Render
            // labelling latency by `statusCode` and `host` — so the label refines the quantile name
            // ("p95 · 200") rather than replacing it. Three lines all reading "p95" would be worse
            // than useless.
            .init(.httpLatency(quantile: 0.5), name: "p50", distinguishingLabel: "statusCode"),
            .init(.httpLatency(quantile: 0.95), name: "p95", distinguishingLabel: "statusCode"),
            .init(.httpLatency(quantile: 0.99), name: "p99", distinguishingLabel: "statusCode"),
        ]
    )

    static let bandwidth = MetricChartSpec(
        id: "bandwidth",
        title: "Bandwidth",
        systemImage: "arrow.up.arrow.down.circle",
        // The one series endpoint that takes no resolution, so Render chooses the buckets.
        footnote: "Outbound transfer, bucketed by Render.",
        series: [.init(.bandwidth, name: "Egress", distinguishingLabel: nil)]
    )

    static let bandwidthBySource = MetricChartSpec(
        id: "bandwidth-sources",
        title: "Bandwidth",
        systemImage: "arrow.up.arrow.down.circle",
        // Render's own total is dropped by the client, so adding up the sources gives it back.
        footnote: "Outbound transfer by how it left, bucketed by Render.",
        headline: .sumOfLatest,
        series: [
            .init(
                .bandwidthSources,
                name: "Egress",
                distinguishingLabel: "trafficSource",
                labelTitles: [
                    "http": "HTTP",
                    "websocket": "WebSocket",
                    "nat": "Outbound (NAT)",
                    "privatelink": "Private Link",
                ]
            )
        ]
    )

    static let replicationLag = MetricChartSpec(
        id: "replication-lag",
        title: "Replication Lag",
        systemImage: "arrow.triangle.2.circlepath",
        footnote: "How far replicas are behind the primary.",
        series: [
            // Asked of the primary, Render returns a series per replica, labelled with the replica's
            // host (its database ID) — read from Render's metrics service, not seen live: no available
            // workspace had a replica. A missing label falls back to the plain name.
            .init(.replicationLag, name: "Lag", distinguishingLabel: "host")
        ]
    )

    // Datastore-only: services never chart connections, so this spec ships with the Postgres and
    // Key Value screens even though the endpoint predates them.
    static let activeConnections = MetricChartSpec(
        id: "active-connections",
        title: "Connections",
        systemImage: "point.3.connected.trianglepath.dotted",
        series: [.init(.activeConnections, name: "Connections", distinguishingLabel: nil)]
    )

    static let disk = MetricChartSpec(
        id: "disk",
        title: "Disk",
        systemImage: "internaldrive",
        series: [
            .init(.diskUsage, name: "Used", distinguishingLabel: nil),
            .init(.diskCapacity, name: "Capacity", role: .reference, distinguishingLabel: nil),
        ]
    )
}
