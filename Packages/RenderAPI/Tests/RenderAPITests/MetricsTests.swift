import Foundation
import RenderAPITestSupport
import Testing

@testable import RenderAPI

/// Tests for the metrics layer, driven through the **real** generated client with only the transport
/// stubbed — so they cover the query the fourteen-way switch in `MetricsQuery.swift` actually builds
/// and the response the generated decoder actually produces, not a re-implementation of either.
@Suite("Metrics")
struct MetricsTests {
    // MARK: - Fixtures

    /// A metrics response, in the one shape all fourteen endpoints share.
    private func seriesJSON(
        labels: [(String, String)] = [("instance", "srv-abc-xyz")],
        points: [(String, Double)] = [("2026-08-12T10:00:00Z", 0.25), ("2026-08-12T10:01:00Z", 0.5)],
        unit: String = "%"
    ) -> String {
        let labelJSON = labels.map { #"{"field":"\#($0.0)","value":"\#($0.1)"}"# }
        let pointJSON = points.map { #"{"timestamp":"\#($0.0)","value":\#($0.1)}"# }
        return """
            [{"labels":[\(labelJSON.joined(separator: ","))],\
            "values":[\(pointJSON.joined(separator: ","))],"unit":"\(unit)"}]
            """
    }

    private var query: MetricsQuery {
        MetricsQuery(
            resourceID: "srv-abc",
            startTime: Date(timeIntervalSince1970: 1_786_000_000),
            endTime: Date(timeIntervalSince1970: 1_786_003_600),
            resolutionSeconds: 60
        )
    }

    // MARK: - Decoding

    @Test("a response decodes into the shared series type, units and all")
    func decodesSeries() async throws {
        let (client, _) = RenderClient.stubbed(jsonBodies: [seriesJSON(unit: "GB")])

        let series = try await client.metricSeries(.memory, query)

        let first = try #require(series.first)
        #expect(first.unit == "GB")
        #expect(first[label: "instance"] == "srv-abc-xyz")
        #expect(first.points.map(\.value) == [0.25, 0.5])
        // The unit is read off the series, not hard-coded per endpoint — the Phase 0 survey found
        // only the *datapoint* unit missing from the spec, and this is the sibling that isn't.
        #expect(first.id == "instance=srv-abc-xyz")
    }

    @Test("microsecond timestamps decode, like everywhere else in the API")
    func decodesMicrosecondTimestamps() async throws {
        let (client, _) = RenderClient.stubbed(jsonBodies: [
            seriesJSON(points: [("2026-08-12T10:00:00.275356Z", 1)])
        ])

        let series = try await client.metricSeries(.cpu, query)

        #expect(try #require(series.first).points.count == 1)
    }

    @Test("a series with no points is dropped rather than charted")
    func dropsEmptySeries() async throws {
        // What Render sends for a metric a resource doesn't produce. An axis drawn around nothing is
        // worse than an explicit "no data".
        let (client, _) = RenderClient.stubbed(jsonBodies: [seriesJSON(points: [])])

        #expect(try await client.metricSeries(.cpu, query).isEmpty)
    }

    @Test("several series in one response stay distinguishable by their labels")
    func keepsSeriesApart() async throws {
        let body = """
            [{"labels":[{"field":"statusCode","value":"200"}],\
            "values":[{"timestamp":"2026-08-12T10:00:00Z","value":10}],"unit":"requests"},\
            {"labels":[{"field":"statusCode","value":"500"}],\
            "values":[{"timestamp":"2026-08-12T10:00:00Z","value":2}],"unit":"requests"}]
            """
        let (client, _) = RenderClient.stubbed(jsonBodies: [body])

        let series = try await client.metricSeries(.httpRequests(aggregateBy: .statusCode), query)

        #expect(series.map(\.id) == ["statusCode=200", "statusCode=500"])
    }

    // MARK: - Query construction

    @Test("the window and resolution go out on every request")
    func sendsWindow() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [seriesJSON()])

        _ = try await client.metricSeries(.cpu, query)

        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/metrics/cpu?"))
        #expect(path.contains("resource=srv-abc"))
        // `60`, not `60.0`. The spec types resolution as `number`, which made the generated parameter
        // a Double — and Render rejects the decimal outright:
        // "could not parse input 60.0 for field resolutionSeconds". Every chart in the app 400'd until
        // Scripts/number-params.py retyped it as an integer, so this assertion is that patch's guard.
        #expect(path.contains("resolutionSeconds=60"))
        #expect(!path.contains("resolutionSeconds=60.0"))
        #expect(path.contains("startTime="))
        #expect(path.contains("endTime="))
    }

    @Test("resolution is clamped to Render's 30-second floor")
    func clampsResolution() async throws {
        // Asking for finer than 30s is a 400, and a range calculation that rounds down shouldn't be
        // able to cause one.
        let (client, transport) = RenderClient.stubbed(jsonBodies: [seriesJSON()])
        var fine = query
        fine.resolutionSeconds = 5

        _ = try await client.metricSeries(.cpu, fine)

        #expect(try #require(transport.requests.first?.path).contains("resolutionSeconds=30"))
        #expect(MetricsQuery(
            resourceID: "srv-abc", startTime: .now, endTime: .now, resolutionSeconds: 1
        ).resolutionSeconds == 30)
    }

    @Test("the quantile rides on the latency kind, and lands as a query parameter")
    func sendsQuantile() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [seriesJSON(unit: "seconds")])

        _ = try await client.metricSeries(.httpLatency(quantile: 0.95), query)

        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/metrics/http-latency?"))
        // Not `quantile=0.949999988079071`, which is what the spec's `format: float` produced before
        // Scripts/number-params.py — Render picks a pre-computed quantile series off this value, so the
        // literal ought to survive the round trip. (The live pass found Render tolerant of the widened
        // value, returning identical points for both, so this is correctness rather than a fix for a
        // broken feature.)
        #expect(path.contains("quantile=0.95"))
    }

    @Test("three quantiles are three distinct kinds")
    func quantilesAreDistinct() {
        // They're three lines on one chart, so they must not collide as cache keys.
        let ids = [0.5, 0.95, 0.99].map { MetricKind.httpLatency(quantile: $0).id }
        #expect(Set(ids).count == 3)
        #expect(MetricKind.httpRequests(aggregateBy: nil).id
            != MetricKind.httpRequests(aggregateBy: .statusCode).id)
    }

    @Test("bandwidth omits resolutionSeconds, which it doesn't declare")
    func bandwidthOmitsResolution() async throws {
        let (client, transport) = RenderClient.stubbed(jsonBodies: [seriesJSON(unit: "GB")])

        _ = try await client.metricSeries(.bandwidth, query)

        let path = try #require(transport.requests.first?.path)
        #expect(path.hasPrefix("/metrics/bandwidth?"))
        // Sending a parameter an endpoint doesn't declare is how you earn a 400.
        #expect(!path.contains("resolutionSeconds"))
    }

    @Test("instance and aggregation are sent only where the endpoint accepts them")
    func sendsOptionalParametersSelectively() async throws {
        var scoped = query
        scoped.instanceID = "srv-abc-xyz"
        scoped.aggregationMethod = .maximum

        let (cpuClient, cpuTransport) = RenderClient.stubbed(jsonBodies: [seriesJSON()])
        _ = try await cpuClient.metricSeries(.cpu, scoped)
        let cpuPath = try #require(cpuTransport.requests.first?.path)
        #expect(cpuPath.contains("instance=srv-abc-xyz"))
        #expect(cpuPath.contains("aggregationMethod=MAX"))

        // `/metrics/cpu` is the only endpoint in the whole set that declares `aggregationMethod`, and
        // `/metrics/instance-count` declares neither parameter.
        let (countClient, countTransport) = RenderClient.stubbed(jsonBodies: [seriesJSON(unit: "count")])
        _ = try await countClient.metricSeries(.instanceCount, scoped)
        let countPath = try #require(countTransport.requests.first?.path)
        #expect(!countPath.contains("instance="))
        #expect(!countPath.contains("aggregationMethod"))
    }

    @Test("every kind hits its own endpoint")
    func routesEveryKind() async throws {
        let expected: [(MetricKind, String)] = [
            (.cpu, "/metrics/cpu?"),
            (.cpuLimit, "/metrics/cpu-limit?"),
            (.cpuTarget, "/metrics/cpu-target?"),
            (.memory, "/metrics/memory?"),
            (.memoryLimit, "/metrics/memory-limit?"),
            (.memoryTarget, "/metrics/memory-target?"),
            (.httpRequests(aggregateBy: .statusCode), "/metrics/http-requests?"),
            (.httpLatency(quantile: 0.5), "/metrics/http-latency?"),
            (.bandwidth, "/metrics/bandwidth?"),
            (.instanceCount, "/metrics/instance-count?"),
            (.activeConnections, "/metrics/active-connections?"),
            (.diskUsage, "/metrics/disk-usage?"),
            (.diskCapacity, "/metrics/disk-capacity?"),
        ]

        for (kind, prefix) in expected {
            let (client, transport) = RenderClient.stubbed(jsonBodies: [seriesJSON()])
            _ = try await client.metricSeries(kind, query)
            #expect(try #require(transport.requests.first?.path).hasPrefix(prefix), "\(kind.id)")
        }
    }

    // MARK: - Errors

    @Test("a failed metrics request surfaces as a RenderError like any other")
    func mapsErrors() async throws {
        let (client, _) = RenderClient.stubbed(jsonBodies: [#"{"message":"nope"}"#], status: 401)

        do {
            _ = try await client.metricSeries(.cpu, query)
            Issue.record("expected a failure")
        } catch {
            // The generated client wraps a middleware throw in its own `ClientError`, which is what
            // every feature store's `RenderError.wrapping(_:)` is for.
            #expect(RenderError.wrapping(error) == .unauthorized(message: nil))
        }
    }

    // MARK: - Aggregates

    @Test("latest, mean, and peak read off the points")
    func summarizes() async throws {
        let (client, _) = RenderClient.stubbed(jsonBodies: [
            seriesJSON(points: [
                ("2026-08-12T10:00:00Z", 10),
                ("2026-08-12T10:01:00Z", 30),
                ("2026-08-12T10:02:00Z", 20),
            ])
        ])

        let series = try #require(try await client.metricSeries(.cpu, query).first)

        // Render returns points oldest-first, so "latest" is the last one.
        #expect(series.latest?.value == 20)
        #expect(series.mean == 20)
        #expect(series.peak?.value == 30)
    }
}
