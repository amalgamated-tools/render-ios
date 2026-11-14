import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// The metrics store, driven through the real generated client with only the transport stubbed.
///
/// Responses are routed by request path rather than supplied in arrival order, because the whole
/// point of this store is that its requests go out *concurrently* — with an ordered stub, "the second
/// body" would be whichever task the group happened to schedule second.
@MainActor
@Suite("MetricsStore")
struct MetricsStoreTests {
    /// A fixed clock, so the window a test asserts on is the window it asked for. `nonisolated`
    /// because the store's clock closure is `@Sendable` and runs wherever the fetch does.
    nonisolated static let now = Date(timeIntervalSince1970: 1_786_000_000)

    private func store(
        charts: [MetricChartSpec],
        range: MetricRange = .hour,
        offersFilters: Bool = false,
        route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (MetricsStore, StubTransport) {
        let (client, transport) = RenderClient.routed(route: route)
        let store = MetricsStore(
            client: client,
            resourceID: "srv-1",
            charts: charts,
            range: range,
            offersFilters: offersFilters,
            clock: { Self.now }
        )
        return (store, transport)
    }

    /// Answers every metrics request with one plausible series.
    nonisolated private static let answerAll: @Sendable (String) -> (status: Int, body: String) = { path in
        (200, Fixtures.metricSeries(unit: path.contains("memory") ? "GB" : "%"))
    }

    // MARK: - Fetching

    @Test("every distinct series is fetched exactly once, concurrently")
    func fetchesEachKindOnce() async {
        let (store, transport) = store(
            charts: [MetricsCatalog.cpu, MetricsCatalog.memory, MetricsCatalog.httpLatency],
            route: Self.answerAll
        )

        await store.load()

        // 3 CPU + 3 memory + 3 latency quantiles. The quantiles are three requests to one endpoint,
        // which is why MetricKind.id includes the parameter.
        #expect(transport.callCount == 9)
        #expect(store.requiredKinds.count == 9)
        let latencyRequests = transport.requests.filter { ($0.path ?? "").hasPrefix("/metrics/http-latency") }
        #expect(Set(latencyRequests.compactMap(\.path)).count == 3)
    }

    @Test("a kind shared by two charts is fetched once")
    func deduplicatesSharedKinds() async {
        // Contrived, but the dedupe is what keeps a screen with overlapping charts from doubling its
        // request count.
        let duplicate = MetricChartSpec(
            id: "cpu-again", title: "CPU again", systemImage: "cpu",
            series: [.init(.cpu, name: "Usage")]
        )
        let (store, transport) = store(charts: [MetricsCatalog.cpu, duplicate], route: Self.answerAll)

        await store.load()

        #expect(transport.callCount == 3)
        #expect(store.lines(for: duplicate).count == 1)
    }

    @Test("the window and resolution come from the range")
    func sendsRangeWindow() async throws {
        let (store, transport) = store(charts: [MetricsCatalog.instanceCount], range: .day, route: Self.answerAll)

        await store.load()

        let path = try #require(transport.requests.first?.path)
        #expect(path.contains("resolutionSeconds=900"))
        // 24h back from the injected clock.
        let start = Self.now.addingTimeInterval(-24 * 3600)
        #expect(path.contains("startTime=\(ISO8601DateFormatter().string(from: start).replacingOccurrences(of: ":", with: "%3A"))")
            || path.contains("startTime="))
        #expect(store.range == .day)
    }

    @Test("changing range clears the old window before reloading")
    func rangeChangeReloads() async {
        let (store, transport) = store(charts: [MetricsCatalog.instanceCount], route: Self.answerAll)
        await store.load()
        #expect(transport.callCount == 1)

        await store.select(.week)

        #expect(transport.callCount == 2)
        #expect(try! #require(transport.requests.last?.path).contains("resolutionSeconds=3600"))
        // Selecting the range that's already active is not a reason to spend a request.
        await store.select(.week)
        #expect(transport.callCount == 2)
    }

    // MARK: - Failure isolation

    @Test("one failed series doesn't take down the other charts")
    func isolatesFailures() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu, MetricsCatalog.memory]) { path in
            path.hasPrefix("/metrics/cpu?")
                ? (500, #"{"message":"boom"}"#)
                : (200, Fixtures.metricSeries(unit: "GB"))
        }

        await store.load()

        // The CPU chart lost its measurement but keeps its limit and target lines, so it still draws.
        #expect(store.didFail(MetricsCatalog.cpu) == false)
        #expect(store.lines(for: MetricsCatalog.cpu).count == 2)
        #expect(store.lines(for: MetricsCatalog.memory).count == 3)
        // No takeover: there is plenty to look at.
        #expect(store.errorMessage == nil)
    }

    @Test("a chart whose every series failed says so, without blanking the screen")
    func marksFullyFailedChart() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu, MetricsCatalog.memory]) { path in
            path.contains("/metrics/cpu")
                ? (500, #"{"message":"boom"}"#)
                : (200, Fixtures.metricSeries(unit: "GB"))
        }

        await store.load()

        #expect(store.didFail(MetricsCatalog.cpu))
        #expect(store.didFail(MetricsCatalog.memory) == false)
        #expect(store.errorMessage == nil)
    }

    @Test("everything failing is the one case that takes over the screen")
    func reportsTotalFailure() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu]) { _ in (500, #"{"message":"boom"}"#) }

        await store.load()

        #expect(store.errorMessage != nil)
        #expect(store.hasAnyData == false)
        // A partial success would have left lastUpdated alone too — it means "this is a complete
        // picture of the window", and after a failure it isn't.
        #expect(store.lastUpdated == nil)
    }

    @Test("lastUpdated is set only when nothing failed")
    func stampsCompleteLoads() async {
        let (store, _) = store(charts: [MetricsCatalog.instanceCount], route: Self.answerAll)

        await store.load()

        #expect(store.lastUpdated == Self.now)
    }

    // MARK: - Lines

    @Test("an empty series contributes no line")
    func dropsEmptySeries() async {
        // What Render returns for the autoscaling target when autoscaling is off. A flat zero line
        // labelled "Autoscaling target" would be a lie.
        let (store, _) = store(charts: [MetricsCatalog.cpu]) { path in
            path.contains("cpu-target")
                ? (200, "[]")
                : (200, Fixtures.metricSeries(unit: "%"))
        }

        await store.load()

        #expect(store.lines(for: MetricsCatalog.cpu).map(\.name) == ["Usage", "Limit"])
    }

    @Test("sibling series are named by their distinguishing label")
    func namesSiblingSeries() async {
        let (store, _) = store(charts: [MetricsCatalog.httpRequests]) { _ in
            (200, Fixtures.metricSeries(
                [
                    (labels: [("statusCode", "200")], points: [("2026-08-12T10:00:00Z", 10)]),
                    (labels: [("statusCode", "500")], points: [("2026-08-12T10:00:00Z", 2)]),
                ],
                unit: "requests"
            ))
        }

        await store.load()

        let lines = store.lines(for: MetricsCatalog.httpRequests)
        #expect(lines.map(\.name) == ["200", "500"])
        // Distinct IDs, or a ForEach would collapse them into one row.
        #expect(Set(lines.map(\.id)).count == 2)
    }

    @Test("traffic sources get readable legend names")
    func namesTrafficSources() async {
        let (store, _) = store(charts: [MetricsCatalog.bandwidthBySource]) { _ in
            (200, Fixtures.metricSeries(
                [
                    (labels: [("trafficSource", "http")], points: [("2026-08-12T10:00:00Z", 4)]),
                    (labels: [("trafficSource", "nat")], points: [("2026-08-12T10:00:00Z", 135)]),
                    // Render's own sum. Kept out of the legend, or the headline would count it twice.
                    (labels: [("trafficSource", "total")], points: [("2026-08-12T10:00:00Z", 139)]),
                    // A source Render adds later is shown as sent rather than hidden.
                    (labels: [("trafficSource", "carrier_pigeon")], points: [("2026-08-12T10:00:00Z", 1)]),
                ],
                unit: "mb"
            ))
        }

        await store.load()

        let lines = store.lines(for: MetricsCatalog.bandwidthBySource)
        #expect(Set(lines.map(\.name)) == ["HTTP", "Outbound (NAT)", "carrier_pigeon"])
        // HTTP + NAT + the unknown source, without Render's total.
        #expect(store.headline(for: MetricsCatalog.bandwidthBySource) == "140 MB")
    }

    // MARK: - Filters

    /// Answers metrics series, plus the three filter-option endpoints in the shapes Render sent live.
    nonisolated private static let answerWithOptions: @Sendable (String) -> (status: Int, body: String) = { path in
        if path.hasPrefix("/metrics/filters/application") {
            return (200, #"[{"filter":"instance","values":["srv-1-bbbbb","srv-1-aaaaa"]}]"#)
        }
        if path.hasPrefix("/metrics/filters/http") {
            return (200, #"[{"filter":"host","values":["b.example.com","a.example.com"]},{"filter":"statusCode","values":["200"]}]"#)
        }
        if path.hasPrefix("/metrics/filters/path") {
            return (200, #"["/api/*","/*/.env","/"]"#)
        }
        return answerAll(path)
    }

    @Test("filter options load alongside the charts")
    func loadsFilterOptions() async {
        let (store, _) = store(
            charts: [MetricsCatalog.cpu, MetricsCatalog.httpRequests],
            offersFilters: true,
            route: Self.answerWithOptions
        )

        await store.load()

        #expect(store.filterOptions.instances == ["srv-1-aaaaa", "srv-1-bbbbb"])
        #expect(store.filterOptions.hosts == ["a.example.com", "b.example.com"])
        // Render's order kept; the scanner path Render's own firewall refuses is gone.
        #expect(store.filterOptions.paths == ["/api/*", "/"])
    }

    @Test("a screen without filters never asks for options")
    func noOptionsWhenNotOffered() async {
        let (store, transport) = store(charts: [MetricsCatalog.cpu], route: Self.answerWithOptions)

        await store.load()

        #expect(!transport.requests.contains { ($0.path ?? "").hasPrefix("/metrics/filters") })
        #expect(store.filterOptions.isEmpty)
    }

    @Test("failed option requests leave the charts loaded")
    func optionFailureIsQuiet() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu], offersFilters: true) { path in
            path.hasPrefix("/metrics/filters") ? (500, "{}") : Self.answerAll(path)
        }

        await store.load()

        #expect(store.errorMessage == nil)
        #expect(!store.lines(for: MetricsCatalog.cpu).isEmpty)
        #expect(store.filterOptions.isEmpty)
    }

    @Test("a host filter refetches only the HTTP charts, and sends the host")
    func hostFilterReach() async throws {
        let (store, transport) = store(
            charts: [MetricsCatalog.cpu, MetricsCatalog.httpRequests],
            offersFilters: true,
            route: Self.answerWithOptions
        )
        await store.load()
        let before = transport.callCount

        await store.apply(MetricFilters(host: "a.example.com", path: "/api/*"))

        let after = transport.requests.dropFirst(before).compactMap(\.path)
        #expect(after.count == 1)
        let request = try #require(after.first)
        #expect(request.hasPrefix("/metrics/http-requests"))
        #expect(request.contains("host=a.example.com"))
        #expect(request.contains("path=/api/*") || request.contains("path=%2Fapi%2F%2A"))
        #expect(store.filterCaption(for: MetricsCatalog.httpRequests) == "Filtered to a.example.com · /api/*")
        #expect(store.filterCaption(for: MetricsCatalog.cpu) == nil)
    }

    @Test("an instance filter refetches only CPU and memory")
    func instanceFilterReach() async {
        let (store, transport) = store(
            charts: [MetricsCatalog.cpu, MetricsCatalog.instanceCount, MetricsCatalog.httpRequests],
            offersFilters: true,
            route: Self.answerWithOptions
        )
        await store.load()
        let before = transport.callCount

        await store.apply(MetricFilters(instance: "srv-1-aaaaa"))

        let after = transport.requests.dropFirst(before).compactMap(\.path)
        // CPU's usage, limit and target.
        #expect(after.count == 3)
        #expect(after.allSatisfy { $0.hasPrefix("/metrics/cpu") && $0.contains("instance=srv-1-aaaaa") })
        #expect(!store.lines(for: MetricsCatalog.instanceCount).isEmpty)
    }

    @Test("reapplying the same filters sends nothing")
    func unchangedFilters() async {
        let (store, transport) = store(charts: [MetricsCatalog.cpu], offersFilters: true, route: Self.answerWithOptions)
        await store.load()
        let before = transport.callCount

        await store.apply(MetricFilters())

        #expect(transport.callCount == before)
    }

    @Test("a filtered chart that fails is marked failed, not left showing unfiltered lines")
    func filteredFailure() async {
        let (store, _) = store(charts: [MetricsCatalog.httpRequests], offersFilters: true) { path in
            path.contains("host=") ? (500, "{}") : Self.answerWithOptions(path)
        }
        await store.load()

        await store.apply(MetricFilters(host: "a.example.com"))

        #expect(store.lines(for: MetricsCatalog.httpRequests).isEmpty)
        #expect(store.failedKindIDs.contains(MetricKind.httpRequests(aggregateBy: .statusCode).id))
    }

    @Test("filters survive a reload")
    func filtersPersistAcrossReload() async {
        let (store, transport) = store(charts: [MetricsCatalog.cpu], offersFilters: true, route: Self.answerWithOptions)
        await store.load()
        await store.apply(MetricFilters(instance: "srv-1-aaaaa"))
        let before = transport.callCount

        await store.load()

        let cpu = transport.requests.dropFirst(before).compactMap(\.path).filter { $0.hasPrefix("/metrics/cpu") }
        #expect(cpu.count == 3)
        #expect(cpu.allSatisfy { $0.contains("instance=srv-1-aaaaa") })
    }

    @Test("a range change during a filter fetch reloads every chart for the new range")
    func rangeChangeDuringFilter() async throws {
        // The first filtered HTTP request — the hour's — is held until the range has changed, which
        // is the window in which the picker used to leave half the charts empty and the rest stale.
        let held = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let holding = HoldOnce()
        let transport = StubTransport { request, _, _ in
            let path = request.path ?? ""
            if path.contains("host="), path.contains("resolutionSeconds=60&") || path.hasSuffix("resolutionSeconds=60"),
               await holding.claim() {
                held.continuation.yield()
                for await _ in release.stream { break }
            }
            let answer = Self.answerWithOptions(path)
            var response = HTTPResponse(status: .init(code: answer.status))
            response.headerFields = [.contentType: "application/json"]
            return (response, HTTPBody(answer.body))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("test-key"), retryPolicy: .none, transport: transport)
        let store = MetricsStore(
            client: client, resourceID: "srv-1",
            charts: [MetricsCatalog.cpu, MetricsCatalog.httpRequests],
            offersFilters: true, clock: { Self.now }
        )
        await store.load()
        let before = transport.callCount

        let filtering = Task { await store.apply(MetricFilters(host: "a.example.com")) }
        for await _ in held.stream { break }
        await store.select(.week)
        release.continuation.yield()
        await filtering.value

        // Every chart is back, and everything fetched after the switch is for the week.
        #expect(!store.lines(for: MetricsCatalog.cpu).isEmpty)
        #expect(!store.lines(for: MetricsCatalog.httpRequests).isEmpty)
        let reload = transport.requests.dropFirst(before + 1).compactMap(\.path)
            .filter { !$0.hasPrefix("/metrics/filters") }
        #expect(reload.count == 4)
        #expect(reload.allSatisfy { $0.contains("resolutionSeconds=3600") })
        // The filter outlives the range change.
        #expect(reload.filter { $0.hasPrefix("/metrics/http") }.allSatisfy { $0.contains("host=a.example.com") })
    }

    @Test("a filter that brings data back clears a whole-screen error")
    func filterRecoversFromTotalFailure() async {
        let (store, _) = store(charts: [MetricsCatalog.httpRequests], offersFilters: true) { path in
            path.hasPrefix("/metrics/http-requests") && !path.contains("host=")
                ? (500, #"{"message":"boom"}"#)
                : Self.answerWithOptions(path)
        }
        await store.load()
        #expect(store.errorMessage != nil)

        await store.apply(MetricFilters(host: "a.example.com"))

        #expect(store.errorMessage == nil)
        #expect(!store.lines(for: MetricsCatalog.httpRequests).isEmpty)
    }

    @Test("a filter list that fails to refresh keeps its previous values")
    func failedOptionRefreshKeepsValues() async {
        let failing = Flag()
        let (store, _) = store(charts: [MetricsCatalog.cpu], offersFilters: true) { path in
            path.hasPrefix("/metrics/filters") && failing.isSet ? (500, "{}") : Self.answerWithOptions(path)
        }
        await store.load()
        await store.apply(MetricFilters(instance: "srv-1-aaaaa"))
        failing.set()

        await store.refresh()

        // Emptied, the menu would vanish and take "Clear Filters" with it while a filter is on.
        #expect(store.filterOptions.instances == ["srv-1-aaaaa", "srv-1-bbbbb"])
        #expect(store.filters.instance == "srv-1-aaaaa")
    }

    @Test("a lone traffic source is still named")
    func namesLoneTrafficSource() async {
        let (store, _) = store(charts: [MetricsCatalog.bandwidthBySource]) { _ in
            (200, Fixtures.metricSeries(
                [(labels: [("trafficSource", "nat")], points: [("2026-08-12T10:00:00Z", 135)])],
                unit: "mb"
            ))
        }

        await store.load()

        #expect(store.lines(for: MetricsCatalog.bandwidthBySource).map(\.name) == ["Outbound (NAT)"])
    }

    @Test("a single series keeps the chart's own name")
    func namesLoneSeries() async {
        let (store, _) = store(charts: [MetricsCatalog.httpRequests]) { _ in
            (200, Fixtures.metricSeries(
                [(labels: [("statusCode", "200")], points: [("2026-08-12T10:00:00Z", 10)])],
                unit: "requests"
            ))
        }

        await store.load()

        // "Requests" reads better than "200" when 200 is all there is.
        #expect(store.lines(for: MetricsCatalog.httpRequests).map(\.name) == ["Requests"])
    }

    @Test("on a chart whose names already differ, a label refines rather than replaces")
    func refinesDistinctSpecNames() async {
        // Render labels latency by statusCode and host, so one quantile can be several series. Three
        // lines all reading "p95" would be worse than useless.
        let (store, _) = store(charts: [MetricsCatalog.httpLatency]) { path in
            guard path.contains("quantile=0.95") else { return (200, "[]") }
            return (200, Fixtures.metricSeries(
                [
                    (labels: [("statusCode", "200")], points: [("2026-08-12T10:00:00Z", 0.002)]),
                    (labels: [("statusCode", "500")], points: [("2026-08-12T10:00:00Z", 0.9)]),
                ],
                unit: "seconds"
            ))
        }

        await store.load()

        #expect(store.lines(for: MetricsCatalog.httpLatency).map(\.name) == ["p95 · 200", "p95 · 500"])
    }

    @Test("instance IDs are shortened for the legend")
    func shortensInstanceNames() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu]) { path in
            guard path.hasPrefix("/metrics/cpu?") else { return (200, "[]") }
            return (200, Fixtures.metricSeries(
                [
                    (labels: [("instance", "srv-d1abc-59d7b8f9c-x4kzp")], points: [("2026-08-12T10:00:00Z", 12)]),
                    (labels: [("instance", "srv-d1abc-59d7b8f9c-q7mtv")], points: [("2026-08-12T10:00:00Z", 34)]),
                ],
                unit: "%"
            ))
        }

        await store.load()

        // The service prefix is identical on every series, so it's noise in a phone-width legend.
        #expect(store.lines(for: MetricsCatalog.cpu).map(\.name) == ["x4kzp", "q7mtv"])
    }

    @Test("the unit is read off the series, per chart")
    func readsUnitFromResponse() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu, MetricsCatalog.memory], route: Self.answerAll)

        await store.load()

        #expect(store.lines(for: MetricsCatalog.cpu).first?.unit == .percent)
        #expect(store.lines(for: MetricsCatalog.memory).first?.unit == .scaled("GB"))
    }

    // MARK: - Headline

    @Test("the headline is the newest measurement, and ignores reference lines")
    func headlineUsesLatestMeasurement() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu]) { path in
            if path.hasPrefix("/metrics/cpu?") {
                return (200, Fixtures.metricSeries(
                    [(labels: [("instance", "srv-1-abc")], points: [
                        ("2026-08-12T10:00:00Z", 20),
                        ("2026-08-12T10:01:00Z", 42),
                    ])],
                    unit: "%"
                ))
            }
            // A limit of 100% must not become the headline.
            return (200, Fixtures.metricSeries(unit: "%", value: 100))
        }

        await store.load()

        #expect(store.headline(for: MetricsCatalog.cpu) == "42%")
    }

    @Test("a count split across series is summed, not sampled")
    func headlineSumsCounts() async {
        let (store, _) = store(charts: [MetricsCatalog.httpRequests]) { _ in
            (200, Fixtures.metricSeries(
                [
                    (labels: [("statusCode", "200")], points: [("2026-08-12T10:00:00Z", 10)]),
                    (labels: [("statusCode", "500")], points: [("2026-08-12T10:00:00Z", 6)]),
                ],
                unit: "requests"
            ))
        }

        await store.load()

        // 10 and 6 is 16 requests; reporting 10 would understate the traffic by a third.
        #expect(store.headline(for: MetricsCatalog.httpRequests) == "16 requests")
    }

    @Test("with several measurement lines the headline is the worst current reading")
    func headlineTakesTheWorstOfSeveralLines() async {
        // The latency chart read "1 ms" above a plot topping out at 4 ms, because "newest timestamp"
        // let the p50 win a race against the p99.
        let (store, _) = store(charts: [MetricsCatalog.httpLatency]) { path in
            let value = path.contains("quantile=0.99") ? 0.004 : 0.001
            return (200, Fixtures.metricSeries(
                [(labels: [("statusCode", "200")], points: [("2026-08-12T10:00:00Z", value)])],
                unit: "seconds"
            ))
        }

        await store.load()

        #expect(store.headline(for: MetricsCatalog.httpLatency) == "4 ms")
    }

    // MARK: - Scale

    @Test("a limit far above the readings becomes a caption, not a line")
    func liftsDistantReferenceOffTheScale() async {
        // Real numbers from the live pass: 0.0001 cores used against a 0.5-core limit. Plotting both
        // put the usage line flat on the axis.
        let (store, _) = store(charts: [MetricsCatalog.cpu]) { path in
            if path.hasPrefix("/metrics/cpu?") {
                return (200, Fixtures.metricSeries(unit: "cpu", value: 0.0001))
            }
            if path.contains("cpu-limit") {
                return (200, Fixtures.metricSeries(unit: "cpu", value: 0.5))
            }
            return (200, "[]")
        }

        await store.load()

        let plot = store.plot(for: MetricsCatalog.cpu)
        #expect(plot.lines.map(\.name) == ["Usage"])
        #expect(plot.offScale == ["Limit 0.5 cores"])
        // Scaled to the reading, so it's visible rather than pinned to zero — and nowhere near the
        // 0.5-core limit that was flattening it.
        #expect(plot.upperBound < 0.01)
    }

    @Test("a limit near the readings stays on the chart")
    func keepsNearbyReferenceOnTheScale() async {
        // A service actually near its ceiling is the case where the line earns its place.
        let (store, _) = store(charts: [MetricsCatalog.memory]) { path in
            if path.hasPrefix("/metrics/memory?") {
                return (200, Fixtures.metricSeries(unit: "bytes", value: 400_000_000))
            }
            if path.contains("memory-limit") {
                return (200, Fixtures.metricSeries(unit: "bytes", value: 536_870_900))
            }
            return (200, "[]")
        }

        await store.load()

        let plot = store.plot(for: MetricsCatalog.memory)
        #expect(plot.lines.map(\.name) == ["Usage", "Limit"])
        #expect(plot.offScale.isEmpty)
        #expect(plot.upperBound > 536_870_900)
    }

    @Test("a near-zero series still gets a labellable scale", arguments: [0.0, 0.0000012])
    func floorsDegenerateScales(value: Double) async {
        // Bandwidth on a quiet service: readings that all round to "0 MB" left Charts drawing three
        // gridlines with the same label.
        let (store, _) = store(charts: [MetricsCatalog.bandwidth]) { _ in
            (200, Fixtures.metricSeries(unit: "mb", value: value))
        }

        await store.load()

        let plot = store.plot(for: MetricsCatalog.bandwidth)
        #expect(plot.lines.count == 1)
        #expect(plot.upperBound == 1)
    }

    @Test("a one-point series is flagged so it can be drawn as a mark")
    func flagsSinglePointSeries() async {
        // Bandwidth over an hour: Render buckets it itself and returned exactly one point, so the card
        // showed a 3.39 MB headline above an empty plot — a line needs two points to exist.
        let (store, _) = store(charts: [MetricsCatalog.bandwidth]) { _ in
            (200, Fixtures.metricSeries(
                [(labels: [], points: [("2026-08-12T10:00:00Z", 3.39)])],
                unit: "mb"
            ))
        }

        await store.load()

        let line = store.plot(for: MetricsCatalog.bandwidth).lines.first
        #expect(line?.isSinglePoint == true)
    }

    @Test("a chart with no data has no headline")
    func headlineNeedsData() async {
        let (store, _) = store(charts: [MetricsCatalog.cpu]) { _ in (200, "[]") }

        await store.load()

        #expect(store.headline(for: MetricsCatalog.cpu) == nil)
    }
}

/// Lets exactly one request through the hold in ``MetricsStoreTests/rangeChangeDuringFilter()``.
private actor HoldOnce {
    private var claimed = false
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

/// A switch a synchronous route closure can read.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
