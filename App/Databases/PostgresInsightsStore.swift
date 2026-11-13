import Foundation
import RenderAPI

/// The four query-insight reports Render exposes for a Postgres database.
enum PostgresInsight: String, CaseIterable, Identifiable, Sendable {
    case processes
    case topQueries
    case tableSizes
    case tableScans

    var id: Self { self }

    var title: String {
        switch self {
        case .processes: "Active"
        case .topQueries: "Top Queries"
        case .tableSizes: "Sizes"
        case .tableScans: "Seq Scans"
        }
    }

    var emptyMessage: String {
        switch self {
        case .processes: "No queries are running right now."
        case .topQueries: "No query statistics have been collected yet."
        case .tableSizes: "No tables or indexes found."
        case .tableScans: "No sequential scans recorded."
        }
    }
}

/// Spaces out query-insight requests to fit Render's limit.
///
/// Render allows **one** query-insights request per minute, and the allowance is shared by all
/// four endpoints and by every database on the key — a request for a different database, or one
/// that 404s, still spends it (checked against the live API, 2026-11). So the gate is shared
/// app-wide rather than kept per screen, and every attempt is recorded, successful or not.
///
/// Waiting client-side matters because the alternative is worse: a 429 makes `RetryMiddleware`
/// sleep out the `Retry-After` and try again, which looks like a spinner hanging for a minute.
@MainActor
final class InsightsRateGate {
    static let shared = InsightsRateGate()

    let interval: TimeInterval
    private(set) var lastRequestAt: Date?

    init(interval: TimeInterval = 60) {
        self.interval = interval
    }

    /// When the next request may go out, or nil if it may go out now.
    func nextAllowed(now: Date) -> Date? {
        guard let lastRequestAt else { return nil }
        let next = lastRequestAt.addingTimeInterval(interval)
        return next > now ? next : nil
    }

    func record(_ date: Date) {
        lastRequestAt = date
    }
}

// MARK: - Rows

struct PostgresProcessRow: Identifiable, Hashable, Sendable {
    let id: Int
    let query: String
    let state: String?
    let durationSeconds: Double?
    let username: String?
    let applicationName: String?
    let waitEvent: String?
    let isLeader: Bool?
}

struct PostgresTopQueryRow: Identifiable, Hashable, Sendable {
    let id: String
    let query: String
    let calls: Int
    let totalTimeMs: Double
    let meanTimeMs: Double?
    let rows: Int?
}

struct PostgresTableSizeRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isIndex: Bool
    let bytes: Int
}

struct PostgresTableScanRow: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let scans: Int
}

/// One report's rows. Every field in these schemas is optional, so the mapping drops rows that
/// lack whatever makes them meaningful (no query text, no size) rather than showing blanks.
enum PostgresInsightRows: Hashable, Sendable {
    case processes([PostgresProcessRow])
    case topQueries([PostgresTopQueryRow])
    case tableSizes([PostgresTableSizeRow])
    case tableScans([PostgresTableScanRow])

    var isEmpty: Bool {
        switch self {
        case .processes(let rows): rows.isEmpty
        case .topQueries(let rows): rows.isEmpty
        case .tableSizes(let rows): rows.isEmpty
        case .tableScans(let rows): rows.isEmpty
        }
    }
}

struct PostgresInsightResult: Sendable {
    let rows: PostgresInsightRows
    let fetchedAt: Date
}

// MARK: - Store

/// Loads Postgres query insights one report at a time, on request.
///
/// Because of the shared one-per-minute limit (see ``InsightsRateGate``) nothing here loads in
/// parallel or polls. Each report keeps the last result with its time, so switching tabs shows what
/// was already fetched instead of spending the allowance again.
@MainActor
@Observable
final class PostgresInsightsStore {
    var selected: PostgresInsight = .processes
    private(set) var results: [PostgresInsight: PostgresInsightResult] = [:]
    private(set) var errors: [PostgresInsight: String] = [:]
    private(set) var loading: PostgresInsight?

    private let client: RenderClient
    let postgresID: String
    private let gate: InsightsRateGate
    private let now: () -> Date

    init(
        client: RenderClient,
        postgresID: String,
        gate: InsightsRateGate = .shared,
        now: @escaping () -> Date = Date.init
    ) {
        self.client = client
        self.postgresID = postgresID
        self.gate = gate
        self.now = now
    }

    /// When the next request may go out, or nil if it may go out now.
    var nextAllowedAt: Date? { gate.nextAllowed(now: now()) }

    /// Loads `insight` unless it already has a result, an error, or the gate is closed. Used for
    /// the automatic load on open and on switching tabs, which must never queue up a blocked call.
    func loadIfNeeded(_ insight: PostgresInsight) async {
        guard results[insight] == nil, errors[insight] == nil else { return }
        await load(insight)
    }

    /// Fetches `insight` now, if the gate allows. Returns without a request if it doesn't.
    func load(_ insight: PostgresInsight) async {
        guard loading == nil, gate.nextAllowed(now: now()) == nil else { return }
        loading = insight
        defer { loading = nil }
        // Recorded before the call: the server counts the attempt whatever it returns.
        gate.record(now())

        do {
            let rows = try await fetch(insight)
            results[insight] = PostgresInsightResult(rows: rows, fetchedAt: now())
            errors[insight] = nil
        } catch {
            let wrapped = RenderError.wrapping(error)
            if case .rateLimited = wrapped {
                errors[insight] = "Render allows one query-insights request a minute, and another device or tool used it. Try again shortly."
            } else {
                errors[insight] = wrapped.errorDescription
            }
        }
    }

    private func fetch(_ insight: PostgresInsight) async throws -> PostgresInsightRows {
        let api = client.api
        switch insight {
        case .processes:
            let body = try await api.listPostgresProcesses(path: .init(postgresId: postgresID)).ok.body.json
            return .processes(Self.processRows(body.processes))
        case .topQueries:
            let body = try await api.listPostgresTopQueries(path: .init(postgresId: postgresID)).ok.body.json
            return .topQueries(Self.topQueryRows(body.topQueries))
        case .tableSizes:
            let body = try await api.listPostgresSizes(path: .init(postgresId: postgresID)).ok.body.json
            return .tableSizes(Self.sizeRows(body.sizes))
        case .tableScans:
            let body = try await api.listPostgresTableScans(path: .init(postgresId: postgresID)).ok.body.json
            return .tableScans(Self.scanRows(body.tableScans))
        }
    }

    // MARK: Mapping

    /// Longest-running first: the question on call is "what's stuck".
    static func processRows(
        _ payload: Operations.ListPostgresProcesses.Output.Ok.Body.JsonPayload.ProcessesPayload
    ) -> [PostgresProcessRow] {
        payload.compactMap { process -> PostgresProcessRow? in
            guard let pid = process.pid else { return nil }
            return PostgresProcessRow(
                id: pid,
                query: process.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                state: process.state,
                durationSeconds: process.duration,
                username: process.username,
                applicationName: process.applicationName.flatMap { $0.isEmpty ? nil : $0 },
                waitEvent: [process.waitEventType, process.waitEvent]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: ": ")
                    .nilIfEmpty,
                isLeader: process.isLeader
            )
        }
        .sorted { ($0.durationSeconds ?? -1) > ($1.durationSeconds ?? -1) }
    }

    /// Most total time first — the queries costing the database the most overall.
    static func topQueryRows(
        _ payload: Operations.ListPostgresTopQueries.Output.Ok.Body.JsonPayload.TopQueriesPayload
    ) -> [PostgresTopQueryRow] {
        payload.enumerated().compactMap { offset, query -> PostgresTopQueryRow? in
            guard let text = query.query?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return PostgresTopQueryRow(
                id: query.queryId ?? "row-\(offset)",
                query: text,
                calls: query.calls ?? 0,
                totalTimeMs: query.totalTimeMs ?? 0,
                meanTimeMs: query.meanTimeMs,
                rows: query.rows
            )
        }
        .sorted { $0.totalTimeMs > $1.totalTimeMs }
    }

    static func sizeRows(
        _ payload: Operations.ListPostgresSizes.Output.Ok.Body.JsonPayload.SizesPayload
    ) -> [PostgresTableSizeRow] {
        payload.compactMap { size -> PostgresTableSizeRow? in
            guard let bytes = size.bytes, let table = size.table ?? size.index else { return nil }
            let index = size.index?.isEmpty == false ? size.index : nil
            let name = qualified(schema: size.schema, name: index ?? table)
            return PostgresTableSizeRow(
                id: [size.database, size.schema, size.table, size.index].map { $0 ?? "" }.joined(separator: "/"),
                name: name,
                isIndex: index != nil,
                bytes: bytes
            )
        }
        .sorted { $0.bytes > $1.bytes }
    }

    static func scanRows(
        _ payload: Operations.ListPostgresTableScans.Output.Ok.Body.JsonPayload.TableScansPayload
    ) -> [PostgresTableScanRow] {
        payload.compactMap { scan -> PostgresTableScanRow? in
            guard let table = scan.table, let scans = scan.scans else { return nil }
            return PostgresTableScanRow(
                id: [scan.database, scan.schema, scan.table].map { $0 ?? "" }.joined(separator: "/"),
                name: qualified(schema: scan.schema, name: table),
                scans: scans
            )
        }
        .sorted { $0.scans > $1.scans }
    }

    /// `public` is the default schema and only adds noise; anything else is worth showing.
    private static func qualified(schema: String?, name: String) -> String {
        guard let schema, !schema.isEmpty, schema != "public" else { return name }
        return "\(schema).\(name)"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
