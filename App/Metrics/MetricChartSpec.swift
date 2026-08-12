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

        var id: String { kind.id }

        init(_ kind: MetricKind, name: String, role: Role = .measurement, distinguishingLabel: String? = "instance") {
            self.kind = kind
            self.name = name
            self.role = role
            self.distinguishingLabel = distinguishingLabel
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
        if hasBandwidth(service.type) {
            charts.append(bandwidth)
        }
        // The disk endpoints answer for the disk attached to a service, so with no disk there is
        // nothing to ask about — unlike the cases above, this one isn't a judgement call.
        if service.details.disk != nil {
            charts.append(disk)
        }
        return charts
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

    private static func hasBandwidth(_ type: Components.Schemas.ServiceType) -> Bool {
        // Egress. A private service has no public traffic, and a worker and a cron job aren't
        // addressable at all.
        type == .webService || type == .staticSite
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
            .init(.httpLatency(quantile: 0.5), name: "p50", distinguishingLabel: nil),
            .init(.httpLatency(quantile: 0.95), name: "p95", distinguishingLabel: nil),
            .init(.httpLatency(quantile: 0.99), name: "p99", distinguishingLabel: nil),
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
