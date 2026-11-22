import Foundation
import Observation
import RenderAPI

/// How many of a workflow's runs finished in the last seven days, and how many of those failed.
///
/// **What's counted.** Render counts per workflow, and the counts include the workflow's flow runs as
/// well as its task runs. Asked for a single task, the endpoint returns zeros, so there's no per-task
/// breakdown. See `Scripts/metrics-quirks.py`.
///
/// **The window.** Render buckets these counts by UTC day, and a bucket counts in full even when the
/// requested start falls inside it. So the window starts at a UTC midnight: seven whole days, today
/// included, rather than a 168-hour window that quietly covers part of an eighth day. Finer buckets
/// over a week get a 500.
///
/// Kept apart from ``WorkflowDetailStore`` so a failed count never hides the workflow itself.
@MainActor
@Observable
final class WorkflowRunCountsStore {
    struct Counts: Equatable, Sendable {
        let succeeded: Int
        let failed: Int
        var total: Int { succeeded + failed }
    }

    nonisolated static let days = 7

    private(set) var counts: Counts?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    private let client: RenderClient
    private let workflowID: String
    private let clock: @Sendable () -> Date

    init(client: RenderClient, workflowID: String, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.workflowID = workflowID
        self.clock = clock
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let (start, end) = Self.window(endingAt: clock())
        do {
            let series = try await client.metricSeries(
                .taskRunsCompleted,
                MetricsQuery(resourceID: workflowID, startTime: start, endTime: end, resolutionSeconds: 86_400)
            )
            counts = Self.counts(from: series)
            errorMessage = nil
        } catch {
            // Keep the last counts on screen; a refresh that fails shouldn't blank them.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    /// From the UTC midnight `days - 1` days before `now`, to `now`.
    nonisolated static func window(endingAt now: Date) -> (start: Date, end: Date) {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let today = utc.startOfDay(for: now)
        let start = utc.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        return (start, now)
    }

    /// Sums each outcome's buckets. A series with an outcome Render adds later is left out rather
    /// than counted as either.
    nonisolated static func counts(from series: [MetricSeries]) -> Counts {
        func sum(_ state: String) -> Int {
            series
                .filter { $0[label: "taskState"] == state }
                .flatMap(\.points)
                .reduce(0) { $0 + Int($1.value.rounded()) }
        }
        return Counts(succeeded: sum("succeeded"), failed: sum("failed"))
    }
}
