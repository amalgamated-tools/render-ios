import RenderAPI
import SwiftUI

/// Query insights for one Postgres database: what's running, what's expensive, what's big, and
/// what's being scanned sequentially.
///
/// One report per tab, fetched on demand. Render allows a single insights request a minute, so
/// the screen says when the next one is possible instead of letting a request sit blocked.
struct PostgresInsightsView: View {
    @State private var store: PostgresInsightsStore

    init(client: RenderClient, postgresID: String) {
        _store = State(initialValue: PostgresInsightsStore(client: client, postgresID: postgresID))
    }

    var body: some View {
        List {
            Section {
                Picker("Report", selection: $store.selected) {
                    ForEach(PostgresInsight.allCases) { insight in
                        Text(insight.title).tag(insight)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            content(for: store.selected)
        }
        .navigationTitle("Query Insights")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.selected) { await store.loadIfNeeded(store.selected) }
    }

    @ViewBuilder
    private func content(for insight: PostgresInsight) -> some View {
        if store.loading == insight {
            Section { ProgressView().frame(maxWidth: .infinity) }
        } else if let result = store.results[insight] {
            rows(result.rows, empty: insight.emptyMessage)
            Section {
                // A failed refresh keeps the old rows, so say why they didn't update.
                errorLabel(insight)
                refreshRow(insight, fetchedAt: result.fetchedAt)
            }
        } else {
            Section {
                errorLabel(insight)
                refreshRow(insight, fetchedAt: nil)
            }
        }
    }

    @ViewBuilder
    private func errorLabel(_ insight: PostgresInsight) -> some View {
        if let message = store.errors[insight] {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }

    /// The load button, or how long until it's allowed. Ticks each second so the countdown and
    /// the button's enabled state stay current without the store polling.
    private func refreshRow(_ insight: PostgresInsight, fetchedAt: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let nextAllowed = store.nextAllowedAt.flatMap { $0 > context.date ? $0 : nil }
            VStack(alignment: .leading, spacing: 4) {
                Button(fetchedAt == nil ? "Load" : "Refresh", systemImage: "arrow.clockwise") {
                    Task { await store.load(insight) }
                }
                .disabled(nextAllowed != nil || store.loading != nil)

                Group {
                    if let nextAllowed {
                        Text("Render allows one request a minute. Available in \(Int(nextAllowed.timeIntervalSince(context.date).rounded(.up)))s.")
                    } else if let fetchedAt {
                        Text("As of \(fetchedAt.formatted(date: .omitted, time: .standard))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func rows(_ rows: PostgresInsightRows, empty: String) -> some View {
        if rows.isEmpty {
            Section { Text(empty).foregroundStyle(.secondary) }
        } else {
            switch rows {
            case .processes(let processes):
                Section("Running") { ForEach(processes) { ProcessRowView(process: $0) } }
            case .topQueries(let queries):
                Section("By total time") { ForEach(queries) { TopQueryRowView(query: $0) } }
            case .tableSizes(let sizes):
                Section("Largest first") {
                    ForEach(sizes) { size in
                        LabeledContent {
                            Text(size.bytes.formatted(.byteCount(style: .file)))
                        } label: {
                            Label(size.name, systemImage: size.isIndex ? "list.bullet.indent" : "tablecells")
                                .lineLimit(1)
                        }
                    }
                }
            case .tableScans(let scans):
                Section {
                    ForEach(scans) { scan in
                        LabeledContent(scan.name, value: scan.scans.formatted())
                    }
                } header: {
                    Text("Most scanned first")
                } footer: {
                    Text("A table scanned sequentially this often may be missing an index.")
                }
            }
        }
    }
}

private struct ProcessRowView: View {
    let process: PostgresProcessRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(process.state ?? "unknown")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(process.state == "active" ? .green : .secondary)
                if let waitEvent = process.waitEvent {
                    Text(waitEvent).font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                if let duration = process.durationSeconds {
                    Text(Duration.seconds(duration).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow)))
                        .font(.caption.monospacedDigit())
                }
            }
            if !process.query.isEmpty {
                Text(process.query)
                    .font(.caption.monospaced())
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Text(["pid \(process.id)", process.username, process.applicationName].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct TopQueryRowView: View {
    let query: PostgresTopQueryRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(query.query)
                .font(.caption.monospaced())
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(spacing: 12) {
                Text("\(query.calls.formatted()) calls")
                Text("total \(Self.milliseconds(query.totalTimeMs))")
                if let mean = query.meanTimeMs {
                    Text("mean \(Self.milliseconds(mean))")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private static func milliseconds(_ value: Double) -> String {
        value >= 1000
            ? (value / 1000).formatted(.number.precision(.fractionLength(1))) + "s"
            : value.formatted(.number.precision(.fractionLength(1))) + "ms"
    }
}
