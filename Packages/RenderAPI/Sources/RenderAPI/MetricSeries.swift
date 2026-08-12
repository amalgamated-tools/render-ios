import Foundation

/// One time series as a `/metrics/*` endpoint returns it.
///
/// Every metrics endpoint answers with the *same* JSON shape — a list of series, each carrying
/// labels, timestamped values, and a unit — but none of those schemas is a named component, so the
/// generator emits a separate, unrelated response type per endpoint: fourteen copies of one
/// structure with no common supertype. ``MetricSeries`` is the single type the app sees, and
/// ``MetricSeriesPayload`` is how the fourteen collapse onto it without fourteen hand-written
/// mappers — see `MetricSeries+Payloads.swift`.
public struct MetricSeries: Sendable, Hashable, Identifiable {
    /// What distinguishes this series from the others in the same response: `instance`, `statusCode`,
    /// `quantile`, and so on. A single-resource query usually returns one series per instance.
    public struct Label: Sendable, Hashable {
        public let field: String
        public let value: String

        public init(field: String, value: String) {
            self.field = field
            self.value = value
        }
    }

    public struct Point: Sendable, Hashable {
        public let timestamp: Date
        public let value: Double

        public init(timestamp: Date, value: Double) {
            self.timestamp = timestamp
            self.value = value
        }
    }

    public let labels: [Label]
    /// Oldest first, as Render returns them.
    public let points: [Point]
    /// The unit Render reports for this series — `%`, `GB`, `seconds`, and so on.
    ///
    /// Read, not assumed. The Phase 0 survey found that the *datapoint* `unit` is declared required
    /// and then never defined (so the generator drops it), which is true; the series-level `unit`
    /// beside it is well-formed and is the one worth having. Nothing here hard-codes a unit per
    /// endpoint.
    public let unit: String

    /// Stable across refreshes so a chart keeps a series on the same color when the data reloads.
    /// Labels are the only identity a series has — the API assigns no ID.
    public var id: String {
        labels
            .map { "\($0.field)=\($0.value)" }
            .sorted()
            .joined(separator: ",")
    }

    public init(labels: [Label], points: [Point], unit: String) {
        self.labels = labels
        self.points = points
        self.unit = unit
    }

    public subscript(label field: String) -> String? {
        labels.first { $0.field == field }?.value
    }

    /// The newest value, which is what a chart header shows.
    public var latest: Point? { points.last }

    /// Average over the window, ignoring gaps.
    public var mean: Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0) { $0 + $1.value } / Double(points.count)
    }

    public var peak: Point? {
        points.max { $0.value < $1.value }
    }
}

// MARK: - Collapsing the generated response types

/// A generated `.../responses/200/.../LabelsPayloadPayload`.
public protocol MetricSeriesLabelPayload {
    var field: String { get }
    var value: String { get }
}

/// A generated `.../responses/200/.../ValuesPayloadPayload`.
public protocol MetricSeriesPointPayload {
    var timestamp: Date { get }
    var value: Double { get }
}

/// A generated metrics response element.
///
/// The requirements deliberately use the generated property names (`labels`, `values`, `unit`) so
/// every conformance is empty — the generator has already written the members. That keeps the
/// fourteen conformances in `MetricSeries+Payloads.swift` to one line each and, more importantly,
/// makes them *compile-checked*: if a spec change renames a field or moves `unit`, the conformance
/// fails to build instead of the app quietly charting nothing.
public protocol MetricSeriesPayload {
    associatedtype LabelPayload: MetricSeriesLabelPayload
    associatedtype PointPayload: MetricSeriesPointPayload

    var labels: [LabelPayload] { get }
    var values: [PointPayload] { get }
    var unit: String { get }
}

extension MetricSeries {
    public init(_ payload: some MetricSeriesPayload) {
        self.init(
            labels: payload.labels.map { Label(field: $0.field, value: $0.value) },
            points: payload.values.map { Point(timestamp: $0.timestamp, value: $0.value) },
            unit: payload.unit
        )
    }

    /// Maps a whole response body, dropping series that carry no points.
    ///
    /// An empty series is what Render sends for a metric a resource doesn't produce — a static site
    /// has no CPU — and charting it would draw an axis around nothing.
    public static func from(_ payloads: [some MetricSeriesPayload]) -> [MetricSeries] {
        // Spelled out rather than `map(MetricSeries.init)`, which captures the payload metatype and
        // trips the Sendable-metatypes check under strict concurrency.
        payloads.map { MetricSeries($0) }.filter { !$0.points.isEmpty }
    }
}
