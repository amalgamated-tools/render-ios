import Foundation
import Observation
import RenderAPI

/// One service's one-off jobs: history, starting a new one, cancelling one that's still going.
///
/// What the live API showed, which shaped this:
/// - **A job runs on its service's image and plan, and the Free plan can't run one.** Render answers
///   `400 "free tier plans are not supported for jobs"`. `startUnavailableReason(plan:)` says so up
///   front rather than letting the user type a command only to be refused.
/// - **Starting and cancelling both answer with the job itself**, so the list is updated from the
///   reply rather than refetched.
/// - **A job finishes on its own schedule.** While any job on screen is pending or running, each of
///   those is re-read on a timer, and the timer stops as soon as none are.
@MainActor
@Observable
final class JobsStore {
    private(set) var jobs: [JobSummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = true
    /// Set while a start or cancel is in flight: the job ID being cancelled, or `startKey` for a start.
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    static let startKey = "start"

    private let client: RenderClient
    let serviceID: String
    private let pageSize: Int
    private let pollInterval: Duration
    private var nextCursor: String?
    private var pollTask: Task<Void, Never>?

    init(client: RenderClient, serviceID: String, pageSize: Int = 20, pollInterval: Duration = .seconds(4)) {
        self.client = client
        self.serviceID = serviceID
        self.pageSize = pageSize
        self.pollInterval = pollInterval
    }

    /// Why this service can't start a job, or `nil` when it can. Only the Free plan is known to be
    /// refused; anything else is left to Render to answer.
    static func startUnavailableReason(plan: Components.Schemas.Plan?) -> String? {
        plan == .free ? "Jobs need a paid instance type. This service is on Free." : nil
    }

    // MARK: - Reading

    func refresh() async {
        jobs = []
        nextCursor = nil
        hasMore = true
        errorMessage = nil
        await loadNextPage()
        startPollingIfNeeded()
    }

    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await makePaginator().firstPage(after: nextCursor)
            // A job started while the first page was loading is already at the top; don't list it twice.
            let known = Set(jobs.map(\.id))
            jobs.append(contentsOf: page.elements.filter { !known.contains($0.id) })
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            hasMore = false
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func dismissActionResult() {
        actionResult = nil
    }

    // MARK: - Writing

    /// Starts a job running `command` on this service. Returns whether Render accepted it.
    @discardableResult
    func start(command: String) async -> Bool {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, writeInFlight == nil else { return false }

        writeInFlight = Self.startKey
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let job = try await client.api.postJob(
                path: .init(serviceId: serviceID),
                body: .json(.init(startCommand: command))
            ).created.body.json
            let summary = JobSummary(job)
            jobs.removeAll { $0.id == summary.id }
            jobs.insert(summary, at: 0)
            actionResult = .success("Job started.")
            startPollingIfNeeded()
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    func cancel(jobID: String) async {
        guard writeInFlight == nil else { return }
        writeInFlight = jobID
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            let job = try await client.api.cancelJob(
                path: .init(serviceId: serviceID, jobId: jobID)
            ).ok.body.json
            replace(JobSummary(job))
            actionResult = .success("Job canceled.")
        } catch {
            actionResult = .failure(error)
            // The job may have finished between the tap and the request; show where it actually is.
            await reread(jobID: jobID)
        }
        startPollingIfNeeded()
    }

    /// Re-reads one job. Used by the detail screen, which opens on the list's copy.
    func reread(jobID: String) async {
        do {
            let job = try await client.api.retrieveJob(
                path: .init(serviceId: serviceID, jobId: jobID)
            ).ok.body.json
            replace(JobSummary(job))
        } catch {
            // Polling and the detail refresh both land here. A missed read leaves the last known
            // state on screen, and the next tick tries again.
        }
    }

    func job(id: String) -> JobSummary? {
        jobs.first { $0.id == id }
    }

    // MARK: - Internals

    private func replace(_ job: JobSummary) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    private func startPollingIfNeeded() {
        guard jobs.contains(where: \.isActive) else {
            stopPolling()
            return
        }
        guard pollTask == nil else { return }

        let interval = pollInterval
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                for id in self.jobs.filter(\.isActive).map(\.id) {
                    await self.reread(jobID: id)
                }
                if !self.jobs.contains(where: \.isActive) {
                    self.pollTask = nil
                    return
                }
            }
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.JobWithCursor, JobSummary> {
        let client = client
        let serviceID = serviceID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listJob(path: .init(serviceId: serviceID), query: .init(cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            (JobSummary(envelope.job), envelope.cursor)
        }
    }
}

extension Components.Schemas.ServiceType {
    /// One-off jobs run a command on the service's own image, so they need a service that has one.
    /// A static site is files on a CDN.
    var supportsJobs: Bool { self != .staticSite }
}
