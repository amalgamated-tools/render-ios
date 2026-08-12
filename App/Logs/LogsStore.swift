import Foundation
import Observation
import RenderAPI

/// Backs the log screen: a page-by-page history walking backwards in time, an optional live tail
/// prepending to the same list, and a client-side search over what's loaded.
///
/// **Paging is by time window, not cursor.** `GET /logs` returns `hasMore` plus the
/// `nextStartTime`/`nextEndTime` to ask for, which is a better signal than the cursor convention
/// used elsewhere — Render tells us directly when the range is exhausted rather than making us infer
/// it from a short page. Windows are inclusive at the edges, so pages overlap by a line or two; IDs
/// are de-duplicated.
///
/// The list is newest-first, which makes the live tail a prepend and the next page an append.
@MainActor
@Observable
final class LogsStore {
    /// What the live tail is doing. `off` and `failed` are distinct on purpose: one is a choice, the
    /// other is something the user should be told about.
    enum LiveStatus: Equatable {
        case off
        case connecting
        case live
        case reconnecting(attempt: Int)
        case failed(String)
    }

    private(set) var lines: [LogLine] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = true
    private(set) var liveStatus: LiveStatus = .off
    /// Lines held back while the tail is paused, newest first. Kept rather than dropped so pausing
    /// to read something doesn't cost you the lines that arrive while you read it.
    private(set) var pendingLines: [LogLine] = []
    private(set) var isPaused = false

    /// Client-side, over loaded lines only — instant, and doesn't disturb the live tail. Searching
    /// the *server* is what the filter sheet's text field does.
    var searchText = ""

    /// Server-side filters. Changing this re-runs the query from scratch, live tail included.
    var filter = LogFilter()

    let ownerID: String
    let resourceIDs: [String]

    private let client: RenderClient
    private let pageSize: Int
    /// Hard cap on retained lines. A busy service emits thousands a minute and the oldest ones off
    /// the bottom of a phone screen aren't worth the memory.
    private let maxLines: Int
    /// The window edges for the *next* page, straight from the last response.
    private var nextStartTime: Date?
    private var nextEndTime: Date?
    private var seenIDs: Set<String> = []
    private var liveTask: Task<Void, Never>?
    /// Incremented every time a tail starts or stops, so a task outliving its `cancel()` can tell
    /// that its state updates are no longer wanted.
    private var liveGeneration = 0

    /// - Parameters:
    ///   - resourceIDs: What to show logs for. A service ID, usually.
    ///   - pageSize: Render caps `limit` at 100.
    init(
        client: RenderClient,
        ownerID: String,
        resourceIDs: [String],
        pageSize: Int = 100,
        maxLines: Int = 2000
    ) {
        self.client = client
        self.ownerID = ownerID
        self.resourceIDs = resourceIDs
        self.pageSize = pageSize
        self.maxLines = maxLines
    }

    /// Lines after the client-side search. Matches message text or any label value, because
    /// "search for the instance ID I just saw" is a real thing to want.
    var visibleLines: [LogLine] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return lines }
        return lines.filter { line in
            line.message.lowercased().contains(needle)
                || line.labels.contains { $0.value.lowercased().contains(needle) }
        }
    }

    var isLive: Bool {
        liveStatus != .off
    }

    /// The whole visible buffer as text, for share/copy.
    var exportText: String {
        // Oldest first: a log someone pastes into a ticket should read top-to-bottom in time.
        visibleLines.reversed().map(\.copyText).joined(separator: "\n")
    }

    // MARK: - History

    /// Clears everything and loads the newest page. Also restarts the live tail if it was running,
    /// since a changed filter invalidates the socket's subscription too.
    func refresh() async {
        lines = []
        pendingLines = []
        seenIDs = []
        nextStartTime = nil
        nextEndTime = nil
        hasMore = true
        errorMessage = nil
        if isLive { restartLiveTail() }
        await loadNextPage()
    }

    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await client.api
                .listLogs(query: filter.query(ownerID: ownerID, resourceIDs: resourceIDs)
                    .listLogsQuery(startTime: nextStartTime, endTime: nextEndTime, limit: pageSize))
                .ok.body.json

            append(page.logs.map(LogLine.init))
            // Render hands back the exact window to ask for next, so there's nothing to compute —
            // and nothing to get wrong when two lines share a timestamp.
            nextStartTime = page.nextStartTime
            nextEndTime = page.nextEndTime
            hasMore = page.hasMore
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            // Stop the footer from immediately retrying in a loop; the retry button re-arms it.
            hasMore = false
        }
    }

    /// Re-arms paging after a failure, then tries the same page again.
    func retry() async {
        errorMessage = nil
        hasMore = true
        await loadNextPage()
    }

    // MARK: - Live tail

    func toggleLive() {
        isLive ? stopLiveTail() : startLiveTail()
    }

    func startLiveTail() {
        guard liveTask == nil else { return }
        liveGeneration += 1
        let generation = liveGeneration
        liveStatus = .connecting
        isPaused = false
        let query = filter.query(ownerID: ownerID, resourceIDs: resourceIDs)
        liveTask = Task { [weak self] in
            await self?.runLiveTail(query: query, generation: generation)
        }
    }

    func stopLiveTail() {
        // Bumping the generation orphans the running task's state updates: cancellation isn't
        // instant, and a tail restarted by a filter change must not have the old one's "reconnecting"
        // or "failed" land on it a moment later.
        liveGeneration += 1
        liveTask?.cancel()
        liveTask = nil
        liveStatus = .off
        // Anything held back becomes ordinary history rather than being thrown away.
        flushPending()
        isPaused = false
    }

    private func runLiveTail(query: LogQuery, generation: Int) async {
        do {
            for try await event in client.logs.subscribe(to: query) {
                guard generation == liveGeneration else { return }
                switch event {
                case .connected:
                    liveStatus = .live
                case .reconnecting(let attempt, _):
                    liveStatus = .reconnecting(attempt: attempt)
                case .entry(let entry):
                    receive(LogLine(entry))
                }
            }
            // Finishing without an error only happens on cancellation, which `stopLiveTail` has
            // already accounted for.
            guard generation == liveGeneration else { return }
            liveStatus = .off
        } catch {
            guard generation == liveGeneration else { return }
            liveStatus = .failed(RenderError.wrapping(error).errorDescription ?? "The log stream stopped.")
        }
        liveTask = nil
    }

    /// Freezes the list without dropping the socket. New lines queue up in ``pendingLines``.
    func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { flushPending() }
    }

    private func receive(_ line: LogLine) {
        guard !seenIDs.contains(line.id) else { return }
        if isPaused {
            seenIDs.insert(line.id)
            insertByTimestamp(line, into: &pendingLines)
            // The pending queue is bounded too — a tail left paused overnight shouldn't grow without
            // limit, and the lines it would drop are ones the ring buffer would drop anyway.
            if pendingLines.count > maxLines { pendingLines.removeLast(pendingLines.count - maxLines) }
        } else {
            seenIDs.insert(line.id)
            insertByTimestamp(line, into: &lines)
            trim()
        }
    }

    private func flushPending() {
        guard !pendingLines.isEmpty else { return }
        let pending = pendingLines
        pendingLines = []
        // Already in seenIDs from `receive`, so these skip the ID filter — but not the ordering,
        // since the buffered lines and the visible ones can interleave in time.
        for line in pending.reversed() {
            insertByTimestamp(line, into: &lines)
        }
        trim()
    }

    /// Places a live line at its position in the newest-first list.
    ///
    /// Usually that's index 0 — but `/logs/subscribe` replays a burst of recent history on connect,
    /// and those lines can be older than ones already loaded. Blind prepending put a 3:50 build line
    /// above a 3:55 one on the very first live pass. The scan walks from the top and stops at the
    /// first line that isn't newer, so the common case costs one comparison.
    private func insertByTimestamp(_ line: LogLine, into list: inout [LogLine]) {
        let index = list.firstIndex { $0.timestamp <= line.timestamp } ?? list.count
        list.insert(line, at: index)
    }

    private func restartLiveTail() {
        stopLiveTail()
        startLiveTail()
    }

    // MARK: - Buffer

    /// History pages walk backwards in time, so a page always belongs at the end of a newest-first
    /// list — no ordering search needed, unlike the live path.
    private func append(_ newLines: [LogLine]) {
        let fresh = newLines.filter { seenIDs.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }
        lines.append(contentsOf: fresh)
        trim()
    }

    /// Drops the oldest lines past the cap. Their IDs stay in `seenIDs`: a line that scrolled off
    /// the end and then arrives again from the live tail is a duplicate, not new.
    private func trim() {
        guard lines.count > maxLines else { return }
        lines.removeLast(lines.count - maxLines)
    }
}
