import Charts
import RenderAPI
import SwiftUI

/// The metrics screen: a range picker pinned at the top, then one card per chart.
///
/// Charts are read, not interrogated — this is a triage screen, so each card leads with the current
/// value in text and uses the plot to answer "is this new?". That ordering is why the headline is
/// large and the axis labels are small.
struct MetricsView: View {
    @State private var store: MetricsStore

    init(client: RenderClient, resourceID: String, charts: [MetricChartSpec]) {
        _store = State(initialValue: MetricsStore(client: client, resourceID: resourceID, charts: charts))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(store.charts) { chart in
                    MetricChartCard(chart: chart, store: store)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .top) { rangePicker }
        .navigationTitle("Metrics")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { if store.seriesByKind.isEmpty { await store.load() } }
        .overlay { screenState }
    }

    private var rangePicker: some View {
        VStack(spacing: 4) {
            Picker("Time range", selection: Binding(
                get: { store.range },
                set: { newRange in Task { await store.select(newRange) } }
            )) {
                ForEach(MetricRange.allCases) { range in
                    Text(range.title)
                        .accessibilityLabel(range.accessibilityTitle)
                        .tag(range)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            if let lastUpdated = store.lastUpdated {
                Text("Updated \(lastUpdated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Covers the two whole-screen cases. Everything else is per card, because one broken series is
    /// not a broken screen.
    @ViewBuilder
    private var screenState: some View {
        if store.charts.isEmpty {
            ContentUnavailableView {
                Label("No Metrics", systemImage: "chart.xyaxis.line")
            } description: {
                // Static sites are the real case: no instance, so no CPU, memory, or instance count.
                Text("Render doesn't report metrics for this kind of service.")
            }
        } else if let message = store.errorMessage {
            ErrorStateView(subject: "metrics", message: message) { await store.refresh() }
        } else if store.isLoading && !store.hasAnyData {
            // The single spinner the concurrent fetch is for.
            ProgressView()
        }
    }
}

/// One chart card: title, headline reading, plot, legend.
private struct MetricChartCard: View {
    let chart: MetricChartSpec
    let store: MetricsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            if let footnote = chart.footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }

    private var plot: MetricsStore.MetricPlot { store.plot(for: chart) }
    private var lines: [MetricLine] { plot.lines }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(chart.title, systemImage: chart.systemImage)
                .font(.subheadline.weight(.semibold))
            Spacer()
            if let headline = store.headline(for: chart) {
                Text(headline)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .accessibilityLabel("\(chart.title) now \(headline)")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.didFail(chart) {
            unavailable("Couldn't load this metric.", systemImage: "exclamationmark.triangle")
        } else if lines.isEmpty {
            if store.isLoading {
                ProgressView()
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
            } else {
                unavailable("No data in this range.", systemImage: "chart.xyaxis.line")
            }
        } else {
            chartBody
            legend
        }
    }

    private var chartBody: some View {
        Chart {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                ForEach(line.points, id: \.timestamp) { point in
                    if line.isSinglePoint {
                        PointMark(
                            x: .value("Time", point.timestamp),
                            y: .value(line.name, point.value)
                        )
                        .foregroundStyle(color(at: index, role: line.role))
                    }
                    LineMark(
                        x: .value("Time", point.timestamp),
                        y: .value(line.name, point.value),
                        series: .value("Series", line.id)
                    )
                    // Styled directly rather than through `foregroundStyle(by:)` and a scale, so the
                    // hand-rolled legend below can use the same function and actually match. A legend
                    // whose swatch colors drift from the plot is worse than none.
                    .foregroundStyle(color(at: index, role: line.role))
                    .lineStyle(line.role == .reference
                        // Thin and dashed: a ceiling is context for the reading, not the subject.
                        ? StrokeStyle(lineWidth: 1, dash: [4, 3])
                        : StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.monotone)
                }
            }
        }
        .chartLegend(.hidden)
        // Anchored at zero and topped just above the highest plotted value — see
        // `MetricsStore.plot(for:)` for why a far-off limit isn't in this range.
        .chartYScale(domain: 0...plot.upperBound)
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine()
                AxisValueLabel {
                    if let number = value.as(Double.self), let unit = lines.first?.unit {
                        Text(unit.axisLabel(number))
                    }
                }
            }
        }
        .chartXAxis {
            let stride = store.range.axisStride
            AxisMarks(values: .stride(by: stride.component, count: stride.count)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(store.range.axisShowsDate
                            ? date.formatted(.dateTime.month(.abbreviated).day())
                            : date.formatted(date: .omitted, time: .shortened))
                    }
                }
            }
        }
        .frame(height: 140)
    }

    /// Hand-rolled rather than `.chartLegend`, so a reference line's swatch can show that it's thinner
    /// — otherwise "Limit" and "Usage" read as the same kind of thing. Wraps, because a request chart
    /// grouped by status code can have more entries than fit on one line.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                HStack(spacing: 4) {
                    Capsule()
                        .fill(color(at: index, role: line.role))
                        .frame(width: 10, height: line.role == .reference ? 1.5 : 3)
                    Text(line.name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            // A limit too far above the readings to plot still belongs on the card — as the number it
            // is, rather than as a line pinning the reading to the axis.
            ForEach(plot.offScale, id: \.self) { reference in
                Text(reference)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Series colors. Reference lines are deliberately outside the palette — they're all the same
    /// muted gray, because distinguishing "limit" from "target" by hue matters less than keeping both
    /// visually behind the measurements.
    private func color(at index: Int, role: MetricChartSpec.Role) -> Color {
        guard role == .measurement else { return .secondary }
        let palette: [Color] = [.blue, .green, .purple, .orange, .teal, .pink, .indigo, .brown]
        return palette[index % palette.count]
    }

    private func unavailable(_ message: String, systemImage: String) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(height: 140)
            .frame(maxWidth: .infinity)
    }
}
