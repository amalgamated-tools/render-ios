import RenderAPI
import SwiftUI

/// The log screen: newest line at the top, history paging down, an optional live tail pushing in
/// from above.
///
/// Newest-first rather than the terminal convention of newest-at-the-bottom, because a phone opens
/// at the top and the thing you came to read is the most recent line. It also means the live tail
/// never fights the scroll position: new lines land above what you're reading instead of dragging
/// the viewport.
struct LogsView: View {
    @State private var store: LogsStore
    @State private var isShowingFilters = false

    private let client: RenderClient

    init(client: RenderClient, ownerID: String, resourceIDs: [String]) {
        self.client = client
        _store = State(initialValue: LogsStore(client: client, ownerID: ownerID, resourceIDs: resourceIDs))
    }

    var body: some View {
        List {
            ForEach(store.visibleLines) { line in
                LogLineRow(line: line)
            }
            if store.hasMore && store.errorMessage == nil && !store.lines.isEmpty {
                loadingFooter
            }
            if let message = store.errorMessage, !store.lines.isEmpty {
                pagingErrorRow(message)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .searchable(text: $store.searchText, prompt: "Filter loaded lines")
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { liveBar }
        .refreshable { await store.refresh() }
        .task { if store.lines.isEmpty { await store.refresh() } }
        .overlay { emptyState }
        .sheet(isPresented: $isShowingFilters) {
            LogFilterSheet(
                client: client,
                ownerID: store.ownerID,
                resourceIDs: store.resourceIDs,
                filter: store.filter
            ) { updated in
                store.filter = updated
                Task { await store.refresh() }
            }
        }
    }

    // MARK: - Rows

    private var loadingFooter: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .listRowSeparator(.hidden)
        // onAppear, not .task, so it re-fires each time the footer scrolls back into view.
        .onAppear { Task { await store.loadNextPage() } }
    }

    /// A paging failure with lines already on screen is a footer, not a takeover — the lines that
    /// did load are still the ones the user came for.
    private func pagingErrorRow(_ message: String) -> some View {
        VStack(spacing: 6) {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") { Task { await store.retry() } }
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    // MARK: - Chrome

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isShowingFilters = true
            } label: {
                Label(
                    store.filter.isEmpty ? "Filter" : "Filter (\(store.filter.activeCount))",
                    systemImage: store.filter.isEmpty
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(
                    store.isLive ? "Stop Live Tail" : "Start Live Tail",
                    systemImage: store.isLive ? "stop.circle" : "dot.radiowaves.left.and.right"
                ) {
                    store.toggleLive()
                }
                if !store.visibleLines.isEmpty {
                    ShareLink(item: store.exportText) {
                        Label("Share Visible Lines", systemImage: "square.and.arrow.up")
                    }
                    Button("Copy Visible Lines", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = store.exportText
                    }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }

    /// The live-tail control strip. Only present while a tail is running, so the screen stays plain
    /// when it's just history.
    @ViewBuilder
    private var liveBar: some View {
        if store.isLive {
            HStack(spacing: 10) {
                liveIndicator
                Spacer()
                if store.isPaused && !store.pendingLines.isEmpty {
                    Text("\(store.pendingLines.count) new")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Button(store.isPaused ? "Resume" : "Pause", systemImage: store.isPaused ? "play.fill" : "pause.fill") {
                    store.setPaused(!store.isPaused)
                }
                .labelStyle(.titleAndIcon)
                .font(.caption)
                Button("Stop", systemImage: "stop.fill") { store.stopLiveTail() }
                    .labelStyle(.iconOnly)
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
        }
    }

    @ViewBuilder
    private var liveIndicator: some View {
        switch store.liveStatus {
        case .off:
            EmptyView()
        case .connecting:
            Label("Connecting…", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .live:
            Label(store.isPaused ? "Paused" : "Live", systemImage: "dot.radiowaves.left.and.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.isPaused ? Color.secondary : Color.green)
        case .reconnecting(let attempt):
            // Says "some lines were missed" without spelling it out — Render replays nothing across
            // a reconnect, so a gap is exactly what happened.
            Label("Reconnecting (\(attempt))…", systemImage: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = store.errorMessage, store.lines.isEmpty {
            ErrorStateView(subject: "logs", message: message) { await store.retry() }
        } else if store.lines.isEmpty && store.isLoading {
            // Not a SkeletonList: a log line is a monospaced run of text, not a tile and two
            // labels, and a ghost of the wrong shape is worse than an honest spinner.
            ProgressView()
        } else if store.lines.isEmpty {
            ContentUnavailableView {
                Label("No Logs", systemImage: "text.alignleft")
            } description: {
                Text(store.filter.isEmpty
                    ? "Nothing was logged in this time range."
                    : "No logs match the current filters.")
            } actions: {
                if !store.filter.isEmpty {
                    Button("Clear Filters") {
                        store.filter.reset()
                        Task { await store.refresh() }
                    }
                }
            }
        } else if store.visibleLines.isEmpty {
            ContentUnavailableView.search
        }
    }
}

/// One line. Monospaced body, a colored rule down the left for severity, and the request metadata
/// promoted to a subtitle when there is any — at 3am the useful question is usually "which path
/// returned the 500", and that shouldn't need a tap.
private struct LogLineRow: View {
    let line: LogLine
    @State private var isExpanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(line.level.tint)
                .frame(width: 3)
                .clipShape(Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(line.message)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    // Collapsed rows are capped so one long line can't own the screen: a service
                    // whose paths carry a big query string (a renderer taking its input in the URL,
                    // say) otherwise pushes every other line out of view, and scanning newest-first
                    // is the whole point of this list. Tapping the row still shows all of it.
                    .lineLimit(isExpanded ? nil : 4)
                HStack(spacing: 6) {
                    Text(line.timestamp.formatted(date: .omitted, time: .standard))
                    if let subtitle = requestSubtitle {
                        Text(subtitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                if isExpanded {
                    labelGrid
                }
            }
        }
        .padding(.vertical, 3)
        .listRowSeparator(.hidden)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappy) { isExpanded.toggle() } }
        .contextMenu {
            Button("Copy Line", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = line.copyText
            }
        }
    }

    /// `GET 500 /api/orders` — assembled only from what's actually there, so app logs get no
    /// subtitle rather than an empty one.
    private var requestSubtitle: String? {
        let parts = [line.method, line.statusCode, line.path].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var labelGrid: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(line.labels.sorted(by: { $0.name < $1.name }), id: \.self) { label in
                HStack(alignment: .top, spacing: 6) {
                    Text(label.name)
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .leading)
                    Text(label.value)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.system(.caption2, design: .monospaced))
        .padding(.top, 2)
    }
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .info: .blue
        case .debug: .purple
        case .unknown: .gray.opacity(0.4)
        }
    }
}
