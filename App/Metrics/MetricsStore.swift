import Foundation
import Observation
import RenderAPI

/// One line on a chart, ready to draw.
struct MetricLine: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let role: MetricChartSpec.Role
    let points: [MetricSeries.Point]
    let unit: MetricUnit

    var latest: MetricSeries.Point? { points.last }
}

/// Backs the metrics screen: a time range, and every chart's series fetched for it.
///
/// **One spinner, many requests.** A service's charts need up to twelve series and there is no
/// batch endpoint, so they go out concurrently in a single task group and the screen shows one
/// spinner until they're all in. Sequential fetches would make the screen take a dozen round trips
/// to appear; a spinner per chart would make it flicker in twelve places.
///
/// **A failed series is a failed chart, not a failed screen.** Twelve requests give twelve chances
/// to fail, and losing the CPU series is no reason to hide memory. Failures are recorded per kind and
/// the takeover error is reserved for the case where *nothing* arrived — the only case where there's
/// nothing to look at anyway.
@MainActor
@Observable
final class MetricsStore {
    let charts: [MetricChartSpec]
    private(set) var range: MetricRange
    private(set) var isLoading = false
    /// Set only when every series failed — otherwise the failures are per chart.
    private(set) var errorMessage: String?
    private(set) var lastUpdated: Date?

    private(set) var seriesByKind: [String: [MetricSeries]] = [:]
    private(set) var failedKindIDs: Set<String> = []

    private let client: RenderClient
    private let resourceID: String
    /// Injected so a test doesn't depend on the wall clock, and so every chart on one load shares
    /// exactly the same window — twelve calls to `.now` would give twelve slightly different ones.
    private let clock: @Sendable () -> Date

    init(
        client: RenderClient,
        resourceID: String,
        charts: [MetricChartSpec],
        range: MetricRange = .hour,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.resourceID = resourceID
        self.charts = charts
        self.range = range
        self.clock = clock
    }

    /// Every distinct series across every chart. Distinct because `cpu` appearing on two charts is
    /// still one request — and because the three latency quantiles are three, which is exactly what
    /// ``MetricKind/id`` encodes.
    var requiredKinds: [MetricKind] {
        var seen: Set<String> = []
        return charts.flatMap(\.kinds).filter { seen.insert($0.id).inserted }
    }

    var hasAnyData: Bool {
        seriesByKind.values.contains { !$0.isEmpty }
    }

    // MARK: - Loading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let (start, end) = range.window(endingAt: clock())
        let query = MetricsQuery(
            resourceID: resourceID,
            startTime: start,
            endTime: end,
            resolutionSeconds: range.resolutionSeconds
        )

        let client = client
        let results = await withTaskGroup(
            of: (id: String, series: [MetricSeries]?, error: String?).self
        ) { group in
            for kind in requiredKinds {
                group.addTask {
                    do {
                        return (kind.id, try await client.metricSeries(kind, query), nil)
                    } catch {
                        return (kind.id, nil, RenderError.wrapping(error).errorDescription)
                    }
                }
            }
            var collected: [(id: String, series: [MetricSeries]?, error: String?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }

        var loaded: [String: [MetricSeries]] = [:]
        var failed: Set<String> = []
        var firstError: String?
        for result in results {
            if let series = result.series {
                loaded[result.id] = series
            } else {
                failed.insert(result.id)
                firstError = firstError ?? result.error
            }
        }

        seriesByKind = loaded
        failedKindIDs = failed
        // A takeover only when there's nothing else to show. Reporting the first failure's message is
        // enough: twelve requests that all failed almost always failed for the same reason.
        errorMessage = loaded.isEmpty ? (firstError ?? "Couldn't load metrics.") : nil
        lastUpdated = failed.isEmpty ? clock() : lastUpdated
    }

    /// Switches range and reloads. Data is cleared first so the charts can't briefly show the old
    /// window's points against the new window's axis.
    func select(_ newRange: MetricRange) async {
        guard newRange != range else { return }
        range = newRange
        seriesByKind = [:]
        failedKindIDs = []
        errorMessage = nil
        await load()
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    // MARK: - Projection

    /// The lines to draw for a chart, in spec order — measurements first, then reference lines.
    ///
    /// A series that came back empty contributes nothing, which is how a CPU chart on a service with
    /// autoscaling off simply has no target line rather than a flat zero one.
    func lines(for chart: MetricChartSpec) -> [MetricLine] {
        chart.series.flatMap { spec -> [MetricLine] in
            let series = seriesByKind[spec.kind.id] ?? []
            return series.map { one in
                MetricLine(
                    // Suffixed with the series' own identity so several instances of one kind stay
                    // distinct rows in a ForEach.
                    id: series.count > 1 ? "\(spec.id)#\(one.id)" : spec.id,
                    name: name(for: one, spec: spec, siblingCount: series.count),
                    role: spec.role,
                    points: one.points,
                    unit: MetricUnit(apiUnit: one.unit)
                )
            }
        }
    }

    /// The header number: the newest measurement, or the newest measurements added up for a count
    /// that Render split across series. Reference lines never contribute — a chart headline of
    /// "512 MB" that turns out to be the plan's limit rather than the reading would be actively
    /// misleading.
    func headline(for chart: MetricChartSpec) -> String? {
        let measurements = lines(for: chart).filter { $0.role == .measurement }
        guard let unit = measurements.first?.unit else { return nil }
        let latest = measurements.compactMap(\.latest)
        guard !latest.isEmpty else { return nil }

        switch chart.headline {
        case .latest:
            // The most recent point across the measurement lines, not the first line's — with several
            // instances reporting, one can lag a bucket behind.
            guard let newest = latest.max(by: { $0.timestamp < $1.timestamp }) else { return nil }
            return unit.formatted(newest.value)
        case .sumOfLatest:
            return unit.formatted(latest.reduce(0) { $0 + $1.value })
        }
    }

    /// Whether every series this chart needs failed to load. A chart with one line missing still
    /// draws; a chart with nothing says so.
    func didFail(_ chart: MetricChartSpec) -> Bool {
        chart.series.allSatisfy { failedKindIDs.contains($0.kind.id) }
    }

    private func name(for series: MetricSeries, spec: MetricChartSpec.Series, siblingCount: Int) -> String {
        guard siblingCount > 1,
              let field = spec.distinguishingLabel,
              let value = series[label: field]
        else { return spec.name }
        return field == "instance" ? shortInstance(value) : value
    }

    /// `srv-d1abc2de3f4g5h6i7j8k-59d7b8f9c-x4kzp` → `x4kzp`. The service prefix is the same on every
    /// series in the chart, so it's noise in a legend that has to fit on a phone.
    private func shortInstance(_ instance: String) -> String {
        instance.split(separator: "-").last.map(String.init) ?? instance
    }
}
