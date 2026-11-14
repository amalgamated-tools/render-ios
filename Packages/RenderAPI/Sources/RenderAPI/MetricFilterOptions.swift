import Foundation

/// The values a service's metrics can be narrowed by, as Render reports them for a window.
///
/// Fetched rather than typed in, so a filter menu only lists values that exist: an instance that ran
/// in the window, a host that served a request. The three lists come from three endpoints, each of
/// which accepts different parameters than the spec says — see `Scripts/metrics-quirks.py`.
public struct MetricFilterOptions: Sendable, Hashable {
    /// Instance IDs, for CPU and memory.
    public var instances: [String]
    /// Hosts that served HTTP requests, for the HTTP charts.
    public var hosts: [String]
    /// Path patterns Render suggests from recent request logs — `/api/*` — for the HTTP charts.
    public var paths: [String]

    public init(instances: [String] = [], hosts: [String] = [], paths: [String] = []) {
        self.instances = instances
        self.hosts = hosts
        self.paths = paths
    }

    public static let empty = MetricFilterOptions()

    public var isEmpty: Bool { instances.isEmpty && hosts.isEmpty && paths.isEmpty }
}

extension RenderClient {
    /// The instances that reported metrics for a resource in a window. `GET /metrics/filters/application`.
    public func metricInstanceOptions(resourceID: String, startTime: Date, endTime: Date) async throws -> [String] {
        try await api.listApplicationFilterValues(query: .init(
            startTime: startTime, endTime: endTime, resource: resourceID
        )).ok.body.json
            .filter { $0.filter == .instance }
            .flatMap { $0.values ?? [] }
    }

    /// The hosts that served a service's HTTP traffic in a window. `GET /metrics/filters/http`.
    ///
    /// Takes `service`, not `resource`: Render rejects `resource` here with a 400. Status codes come
    /// back too, but are dropped — the series endpoints don't accept a status-code filter, and the
    /// request chart already draws one line per status code.
    public func metricHostOptions(serviceID: String, startTime: Date, endTime: Date) async throws -> [String] {
        try await api.listHttpFilterValues(query: .init(
            startTime: startTime, endTime: endTime, service: serviceID
        )).ok.body.json
            .filter { $0.filter == .host }
            .flatMap { $0.values ?? [] }
    }

    /// Path patterns for a resource's HTTP charts. `GET /metrics/filters/path`.
    ///
    /// No window: Render builds these from the most recent 5000 request log lines and rejects a time
    /// range.
    ///
    /// Patterns containing `.env` are dropped. Render suggests them — they're what vulnerability
    /// scanners request — but passing one back as a filter is refused by Render's own firewall with
    /// a 403 HTML page, so offering it would only lead to an error.
    public func metricPathOptions(resourceID: String) async throws -> [String] {
        try await api.listPathFilterValues(query: .init(resource: resourceID)).ok.body.json
            .filter { !$0.contains(".env") }
    }
}
