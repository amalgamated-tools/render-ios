import Foundation

/// The window every metrics request shares.
///
/// Same motivation as ``LogQuery``: the fourteen `/metrics/*` operations take the same handful of
/// query parameters and the generator emits fourteen unrelated `Input.Query` types for them, so
/// without one description a caller assembles the same window from fourteen vocabularies. What's
/// *specific* to a series — a latency quantile, a request grouping — belongs to the
/// ``MetricKind``, not here.
public struct MetricsQuery: Sendable, Hashable {
    /// One resource per request. The spec declares `resource` as a plain `string` (its own
    /// description says repeating it ORs the values, but the schema doesn't allow an array), so the
    /// generated client can carry exactly one ID. Charting several resources at once would need a
    /// spec patch; a per-service screen doesn't.
    public var resourceID: String
    public var startTime: Date
    public var endTime: Date
    /// Seconds per data point.
    ///
    /// An `Int`, not a `Double`, because Render parses this as an integer and rejects a decimal
    /// outright — `resolutionSeconds=60.0` comes back as
    /// `could not parse input 60.0 for field resolutionSeconds`. The spec says `number`; see
    /// `Scripts/number-params.py`.
    ///
    /// Clamped to Render's documented floor of 30 on the way in, rather than passed through: the
    /// floor is an API constraint, and a coarser chart is a better outcome than a 400 from a range
    /// calculation that rounded down. The clamp lives on the property, not just the initializer, so
    /// it also holds for `query.resolutionSeconds = …` after the fact.
    public var resolutionSeconds: Int {
        get { clampedResolutionSeconds }
        set { clampedResolutionSeconds = max(Self.minimumResolutionSeconds, newValue) }
    }

    public static let minimumResolutionSeconds = 30

    private var clampedResolutionSeconds: Int
    /// Narrows to one instance. Only CPU and memory accept it; ignored elsewhere.
    public var instanceID: String?
    /// Narrows the HTTP series to one host — `api.example.com`. Only the HTTP endpoints accept it;
    /// ignored elsewhere.
    public var host: String?
    /// Narrows the HTTP series to requests matching a path pattern — `/api/*`. Only the HTTP
    /// endpoints accept it; ignored elsewhere.
    public var path: String?
    /// How to combine several instances' series into one. Only `/metrics/cpu` accepts it — an
    /// asymmetry in the spec, not a modelling choice here. `nil` leaves the series per-instance.
    public var aggregationMethod: AggregationMethod?

    public enum AggregationMethod: String, Sendable, Hashable, CaseIterable {
        case average = "AVG"
        case maximum = "MAX"
        case minimum = "MIN"
    }

    public init(
        resourceID: String,
        startTime: Date,
        endTime: Date,
        resolutionSeconds: Int,
        instanceID: String? = nil,
        host: String? = nil,
        path: String? = nil,
        aggregationMethod: AggregationMethod? = nil
    ) {
        self.resourceID = resourceID
        self.startTime = startTime
        self.endTime = endTime
        self.clampedResolutionSeconds = max(Self.minimumResolutionSeconds, resolutionSeconds)
        self.instanceID = instanceID
        self.host = host
        self.path = path
        self.aggregationMethod = aggregationMethod
    }
}

/// Which series to fetch.
///
/// The two endpoints that take a series-shaping parameter carry it in the case, because
/// `httpLatency(quantile: 0.95)` *is* a different series from `httpLatency(quantile: 0.5)` — they're
/// two lines on one chart, not one request configured two ways.
public enum MetricKind: Sendable, Hashable {
    case cpu
    /// The plan's CPU ceiling, for a reference line.
    case cpuLimit
    /// The autoscaling target, present only when autoscaling is on.
    case cpuTarget
    case memory
    case memoryLimit
    case memoryTarget
    /// - Parameter aggregateBy: Splits the response into one series per status code or host.
    ///   `nil` returns a single total.
    case httpRequests(aggregateBy: HTTPRequestGrouping? = nil)
    /// - Parameter quantile: `0.5`, `0.95`, `0.99` — a fraction, not a percentage.
    case httpLatency(quantile: Double)
    case bandwidth
    case instanceCount
    case activeConnections
    case diskUsage
    case diskCapacity
    /// Egress split by where it went — `http`, `websocket`, `nat`, `privatelink` — in the
    /// `trafficSource` label. Render's own `total` series is dropped: the sources add up to it, and
    /// drawn alongside them it would double every reading.
    case bandwidthSources
    /// Postgres replica lag in seconds. Asked of the primary, it returns one series per replica.
    case replicationLag
    /// Task runs that finished in each bucket, one series per outcome in the `taskState` label
    /// (`succeeded`, `failed`). The resource is a *workflow* ID, and the counts include its flow
    /// runs: a task ID returns zeros, whatever the spec says. See `Scripts/metrics-quirks.py`.
    case taskRunsCompleted

    public enum HTTPRequestGrouping: String, Sendable, Hashable, CaseIterable {
        case statusCode
        case host
    }

    /// Stable key for caching and for chart identity. Includes the parameter, so the three latency
    /// quantiles don't collide.
    public var id: String {
        switch self {
        case .cpu: "cpu"
        case .cpuLimit: "cpu-limit"
        case .cpuTarget: "cpu-target"
        case .memory: "memory"
        case .memoryLimit: "memory-limit"
        case .memoryTarget: "memory-target"
        case .httpRequests(let aggregateBy): "http-requests-\(aggregateBy?.rawValue ?? "total")"
        case .httpLatency(let quantile): "http-latency-\(quantile)"
        case .bandwidth: "bandwidth"
        case .instanceCount: "instance-count"
        case .activeConnections: "active-connections"
        case .diskUsage: "disk-usage"
        case .diskCapacity: "disk-capacity"
        case .bandwidthSources: "bandwidth-sources"
        case .replicationLag: "replication-lag"
        case .taskRunsCompleted: "task-runs-completed"
        }
    }
}

extension RenderClient {
    /// Fetches one metric series set.
    ///
    /// The switch is where the per-endpoint asymmetry lives, and it's deliberately explicit: only CPU
    /// takes `aggregationMethod`, only CPU and memory take `instance`, only HTTP takes `host` and
    /// `path`, the two bandwidth endpoints take no `resolutionSeconds` at all, and latency and
    /// requests each take one parameter nothing else does. Passing a parameter an endpoint doesn't declare would be a 400, so this can't be
    /// collapsed into a generic call without dropping information Render needs.
    ///
    /// Series with no data points are dropped — see ``MetricSeries/from(_:)``.
    public func metricSeries(_ kind: MetricKind, _ query: MetricsQuery) async throws -> [MetricSeries] {
        let start = query.startTime
        let end = query.endTime
        let resolution = query.resolutionSeconds
        let resource = query.resourceID
        let instance = query.instanceID

        switch kind {
        case .cpu:
            return MetricSeries.from(
                try await api.getCpu(query: .init(
                    startTime: start,
                    endTime: end,
                    resolutionSeconds: resolution,
                    resource: resource,
                    instance: instance,
                    aggregationMethod: query.aggregationMethod.map {
                        switch $0 {
                        case .average: .avg
                        case .maximum: .max
                        case .minimum: .min
                        }
                    }
                )).ok.body.json
            )
        case .cpuLimit:
            return MetricSeries.from(
                try await api.getCpuLimit(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, instance: instance
                )).ok.body.json
            )
        case .cpuTarget:
            return MetricSeries.from(
                try await api.getCpuTarget(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, instance: instance
                )).ok.body.json
            )
        case .memory:
            return MetricSeries.from(
                try await api.getMemory(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, instance: instance
                )).ok.body.json
            )
        case .memoryLimit:
            return MetricSeries.from(
                try await api.getMemoryLimit(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, instance: instance
                )).ok.body.json
            )
        case .memoryTarget:
            return MetricSeries.from(
                try await api.getMemoryTarget(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, instance: instance
                )).ok.body.json
            )
        case .httpRequests(let aggregateBy):
            return MetricSeries.from(
                try await api.getHttpRequests(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, host: query.host, path: query.path,
                    aggregateBy: aggregateBy.map {
                        switch $0 {
                        case .statusCode: .statusCode
                        case .host: .host
                        }
                    }
                )).ok.body.json
            )
        case .httpLatency(let quantile):
            return MetricSeries.from(
                try await api.getHttpLatency(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, host: query.host, path: query.path,
                    // A Double, not the Float the spec's `format: float` would give — see
                    // Scripts/number-params.py. As a Float this went on the wire as 0.949999988079071
                    // instead of 0.95. (Render turned out to accept both; this is the honest spelling.)
                    quantile: quantile
                )).ok.body.json
            )
        case .bandwidth:
            return MetricSeries.from(
                try await api.getBandwidth(query: .init(
                    // No resolutionSeconds: bandwidth is the one series endpoint that doesn't
                    // declare it, so Render picks the bucket size.
                    startTime: start, endTime: end, resource: resource
                )).ok.body.json
            )
        case .instanceCount:
            return MetricSeries.from(
                try await api.getInstanceCount(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution, resource: resource
                )).ok.body.json
            )
        case .activeConnections:
            return MetricSeries.from(
                try await api.getActiveConnections(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution, resource: resource
                )).ok.body.json
            )
        case .diskUsage:
            return MetricSeries.from(
                try await api.getDiskUsage(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution, resource: resource
                )).ok.body.json
            )
        case .diskCapacity:
            return MetricSeries.from(
                try await api.getDiskCapacity(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution, resource: resource
                )).ok.body.json
            )
        case .bandwidthSources:
            // Like /metrics/bandwidth, no resolutionSeconds. The response shape is corrected by
            // Scripts/metrics-quirks.py — the spec describes one Render doesn't send.
            return MetricSeries.from(
                try await api.getBandwidthSources(query: .init(
                    startTime: start, endTime: end, resource: resource
                )).ok.body.json
            ).filter { $0[label: "trafficSource"] != "total" }
        case .replicationLag:
            return MetricSeries.from(
                try await api.getReplicationLag(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution, resource: resource
                )).ok.body.json
            )
        case .taskRunsCompleted:
            // SUM is the only method Render accepts here, and it rejects a request without one;
            // the spec omits the parameter, so Scripts/metrics-quirks.py adds it as required.
            return MetricSeries.from(
                try await api.getTaskRunsCompleted(query: .init(
                    startTime: start, endTime: end, resolutionSeconds: resolution,
                    resource: resource, aggregateBy: .state, aggregationMethod: .sum
                )).ok.body.json
            )
        }
    }
}
