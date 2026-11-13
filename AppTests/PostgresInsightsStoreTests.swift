import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("PostgresInsightsStore")
struct PostgresInsightsStoreTests {
    /// A clock the test moves by hand, so the one-a-minute gate is testable without waiting.
    final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private func store(
        _ route: @escaping @Sendable (String) -> (status: Int, body: String)
    ) -> (PostgresInsightsStore, StubTransport, Clock) {
        let (client, transport) = RenderClient.routed(route: route)
        let clock = Clock()
        let store = PostgresInsightsStore(
            client: client,
            postgresID: "dpg-1",
            gate: InsightsRateGate(),
            now: { clock.now }
        )
        return (store, transport, clock)
    }

    private nonisolated static let processes = #"""
        {"processes":[
          {"pid":11,"state":"idle","query":"SELECT 1","duration":0.5},
          {"pid":12,"state":"active","query":"  UPDATE big SET x = 1 ","duration":312.0,
           "username":"app","applicationName":"","waitEventType":"Lock","waitEvent":"tuple"},
          {"state":"active","query":"no pid, dropped"}
        ]}
        """#

    private nonisolated static let everything: @Sendable (String) -> (status: Int, body: String) = { path in
        if path.hasSuffix("/query/processes") { return (200, processes) }
        if path.hasSuffix("/query/top-queries") {
            return (200, #"""
                {"topQueries":[
                  {"queryId":"a","query":"SELECT cheap","calls":1000,"totalTimeMs":50,"meanTimeMs":0.05},
                  {"queryId":"b","query":"SELECT costly","calls":3,"totalTimeMs":9000,"meanTimeMs":3000},
                  {"queryId":"c","query":"   "}
                ]}
                """#)
        }
        if path.hasSuffix("/query/sizes") {
            return (200, #"""
                {"sizes":[
                  {"Database":"appdb","Schema":"public","Table":"users","Bytes":1000},
                  {"Database":"appdb","Schema":"audit","Table":"events","Index":"events_pkey","Bytes":5000},
                  {"Database":"appdb","Schema":"public","Table":"no_size"}
                ]}
                """#)
        }
        if path.hasSuffix("/query/table-scans") {
            return (200, #"{"tableScans":[{"Schema":"public","Table":"a","Scans":2},{"Schema":"public","Table":"b","Scans":90}]}"#)
        }
        return (500, "{}")
    }

    @Test("processes map, drop rows without a pid, and sort longest-running first")
    func processes() async throws {
        let (store, transport, _) = store(Self.everything)

        await store.load(.processes)

        guard case .processes(let rows) = try #require(store.results[.processes]).rows else {
            Issue.record("wrong rows"); return
        }
        #expect(rows.map(\.id) == [12, 11])
        #expect(rows[0].query == "UPDATE big SET x = 1")
        #expect(rows[0].waitEvent == "Lock: tuple")
        #expect(rows[0].applicationName == nil)
        #expect(transport.requests.compactMap(\.path) == ["/postgres/dpg-1/query/processes"])
    }

    @Test("top queries sort by total time and skip blank query text")
    func topQueries() async throws {
        let (store, _, _) = store(Self.everything)

        await store.load(.topQueries)

        guard case .topQueries(let rows) = try #require(store.results[.topQueries]).rows else {
            Issue.record("wrong rows"); return
        }
        #expect(rows.map(\.id) == ["b", "a"])
    }

    @Test("sizes read the capitalised fields, qualify non-public schemas, and flag indexes")
    func sizes() async throws {
        let (store, _, _) = store(Self.everything)

        await store.load(.tableSizes)

        guard case .tableSizes(let rows) = try #require(store.results[.tableSizes]).rows else {
            Issue.record("wrong rows"); return
        }
        #expect(rows.map(\.name) == ["audit.events_pkey", "users"])
        #expect(rows.map(\.isIndex) == [true, false])
    }

    @Test("table scans sort most-scanned first")
    func scans() async throws {
        let (store, _, _) = store(Self.everything)

        await store.load(.tableScans)

        guard case .tableScans(let rows) = try #require(store.results[.tableScans]).rows else {
            Issue.record("wrong rows"); return
        }
        #expect(rows.map(\.name) == ["b", "a"])
    }

    @Test("a second request inside the minute is not sent, even for another report")
    func gateBlocksWithinTheMinute() async throws {
        let (store, transport, clock) = store(Self.everything)

        await store.load(.processes)
        clock.now += 30
        await store.load(.topQueries)

        #expect(transport.callCount == 1)
        #expect(store.results[.topQueries] == nil)
        #expect(store.nextAllowedAt == clock.now + 30)

        clock.now += 30
        await store.load(.topQueries)
        #expect(transport.callCount == 2)
        #expect(store.results[.topQueries] != nil)
    }

    @Test("the gate is shared between screens for different databases")
    func gateIsShared() async throws {
        let (client, transport) = RenderClient.routed(route: Self.everything)
        let gate = InsightsRateGate()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = PostgresInsightsStore(client: client, postgresID: "dpg-1", gate: gate, now: { start })
        let second = PostgresInsightsStore(client: client, postgresID: "dpg-2", gate: gate, now: { start + 10 })

        await first.load(.processes)
        await second.load(.processes)

        #expect(transport.callCount == 1)
    }

    @Test("loadIfNeeded doesn't refetch a report that already loaded")
    func loadIfNeededKeepsResults() async throws {
        let (store, transport, clock) = store(Self.everything)

        await store.loadIfNeeded(.processes)
        clock.now += 120
        await store.loadIfNeeded(.processes)

        #expect(transport.callCount == 1)
    }

    @Test("a failure still spends the minute, and a 429 gets its own explanation")
    func failures() async throws {
        let (store, transport, clock) = store { path in
            path.hasSuffix("/processes") ? (404, #"{"message":"not found"}"#) : (429, "{}")
        }

        await store.load(.processes)
        #expect(store.errors[.processes] != nil)
        #expect(store.nextAllowedAt != nil)

        clock.now += 60
        await store.load(.topQueries)
        #expect(transport.callCount == 2)
        #expect(store.errors[.topQueries]?.contains("one query-insights request a minute") == true)
    }

    @Test("an empty report loads as empty, not as an error")
    func emptyReport() async throws {
        let (store, _, _) = store { _ in (200, #"{"processes":[]}"#) }

        await store.load(.processes)

        #expect(try #require(store.results[.processes]).rows.isEmpty)
        #expect(store.errors[.processes] == nil)
    }
}
