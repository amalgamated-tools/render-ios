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

    /// - Parameter offersFilters: Whether to show the instance, host and path filters. For services
    ///   only — see ``MetricsStore/offersFilters``.
    init(client: RenderClient, resourceID: String, charts: [MetricChartSpec], offersFilters: Bool = false) {
        _store = State(initialValue: MetricsStore(
            client: client,
            resourceID: resourceID,
            charts: charts,
            offersFilters: offersFilters
        ))
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
        .toolbar {
            if store.offersFilters && !store.filterOptions.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { filterMenu }
            }
        }
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

    /// One menu for all three filters. Each section only appears when Render reported values for it —
    /// a service with one instance has nothing to choose between.
    private var filterMenu: some View {
        Menu {
            if store.canFilterByInstance && store.filterOptions.instances.count > 1 {
                filterPicker("Instance", values: store.filterOptions.instances, keyPath: \.instance) {
                    MetricsStore.shortInstance($0)
                }
            }
            if store.canFilterHTTP && !store.filterOptions.hosts.isEmpty {
                filterPicker("Host", values: store.filterOptions.hosts, keyPath: \.host) { $0 }
            }
            if store.canFilterHTTP && !store.filterOptions.paths.isEmpty {
                filterPicker("Path", values: store.filterOptions.paths, keyPath: \.path) { $0 }
            }
            if store.filters.isActive {
                Button("Clear Filters", systemImage: "xmark.circle") {
                    Task { await store.apply(MetricFilters()) }
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: store.filters.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        // A change mid-load would be dropped by the store, so the menu waits for the load instead.
        .disabled(store.isLoading)
    }

    private func filterPicker(
        _ title: String,
        values: [String],
        keyPath: WritableKeyPath<MetricFilters, String?>,
        display: @escaping (String) -> String
    ) -> some View {
        Picker(title, selection: Binding(
            get: { store.filters[keyPath: keyPath] },
            set: { value in
                var filters = store.filters
                filters[keyPath: keyPath] = value
                Task { await store.apply(filters) }
            }
        )) {
            Text("All").tag(String?.none)
            ForEach(values, id: \.self) { value in
                Text(display(value)).tag(String?.some(value))
            }
        }
        .pickerStyle(.menu)
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
            if let caption = store.filterCaption(for: chart) {
                Label(caption, systemImage: "line.3.horizontal.decrease")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            content
            if let footnote = chart.footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        // A hairline so the card still has an edge in dark mode, where .background.secondary and
        // the page behind it are nearly the same value.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(.quaternary, lineWidth: 0.5)
        )
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
                    // Rolls digit-by-digit as the poll updates rather than swapping the whole
                    // string, so a changing number reads as the same number changing.
                    .contentTransition(.numericText())
                    .animation(.default, value: headline)
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
                    // Only under measurements, and only when there is one of them: stacked
                    // translucent fills on a multi-series chart muddy every colour they overlap.
                    if line.role == .measurement, lines.filter({ $0.role == .measurement }).count == 1 {
                        AreaMark(
                            x: .value("Time", point.timestamp),
                            y: .value(line.name, point.value),
                            series: .value("Series", line.id)
                        )
                        .foregroundStyle(
                            .linearGradient(
                                colors: [color(at: index, role: line.role).opacity(0.25), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
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
        // Brand violet leads: on the single-series charts that make up most of this screen, it is
        // the only colour shown, and it should be the app's.
        let palette: [Color] = [Color(.accent), .blue, .green, .orange, .teal, .pink, .indigo, .brown]
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
