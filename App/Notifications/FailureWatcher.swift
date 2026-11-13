import Foundation
import RenderAPI

/// One thing worth interrupting someone for.
struct FailureAlert: Identifiable, Hashable, Sendable {
    /// Stable per underlying failure, so re-posting can only ever replace a notification rather than
    /// stack a second copy of it.
    let id: String
    let serviceID: String
    let ownerID: String
    let serviceName: String
    /// What broke, in the notification body. The service name is the title.
    let summary: String
    let occurredAt: Date
    /// The event to open when the notification is tapped. `nil` when the alert came from the deploy
    /// list rather than an event, and the tap opens the service instead.
    var eventID: String? = nil
}

/// Checks every watched service for something that broke since the last look.
///
/// Deliberately free of `BGTaskScheduler`, `UNUserNotificationCenter` and SwiftUI: this is the part
/// with rules worth testing, and all three of those are untestable in a unit test. It takes a
/// client, a watchlist and a set of watermarks, and returns alerts. ``FailureWatchCoordinator`` is
/// what turns those into notifications, on whichever schedule iOS allows.
///
/// **Why one request per watched service.** There is no account-wide events feed in the API — the
/// only listable event collections are per service, per webhook, and per task run. And the
/// per-service endpoint's `type` filter takes a *single* event type, not a list, so narrowing to the
/// types worth alerting on would multiply the request count by eight rather than divide it. One
/// unfiltered request per service since its watermark is the cheapest correct thing available, and
/// on an idle service it comes back empty. It only pages further when that request comes back full
/// — see ``fetchEvents(serviceID:since:)``.
@MainActor
final class FailureWatcher {
    /// Event types where the type alone is the alert. Their details add the cause where Render gives
    /// one ("Server failed: Out of memory (512Mi limit)").
    ///
    /// `deploy_ended` needs its details to say whether it failed, and is handled separately below;
    /// `build_ended` is deliberately absent because a failed build always produces a `deploy_ended`
    /// too, and alerting on both would double-report one failure.
    static let selfDescribingFailures: Set<Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload> = [
        .serverFailed,
        .serverHardwareFailure,
        .imagePullFailed,
        .artifactFetchFailed,
        .commitIgnored,
        .pipelineMinutesExhausted,
        .serviceSuspended,
        // A disk filling up is the one capacity warning worth waking someone for: unlike a plan or
        // scaling change, it ends in an outage if nobody acts. Its `recovered` counterpart is
        // deliberately absent — good news can wait for the timeline.
        .serviceDiskUsageHigh,
    ]

    private let client: RenderClient
    private let watchlist: WatchlistStore
    private let watermarks: EventWatermarkStore
    private let now: @Sendable () -> Date
    private let concurrency: Int
    private let pageLimit: Int
    private let maxPages: Int

    /// - Parameters:
    ///   - concurrency: How many services are checked at once. `RetryMiddleware` already handles
    ///     429s, but a background wake has seconds to work with — better not to provoke a retry.
    ///   - pageLimit: The endpoint caps `limit` at 100.
    ///   - maxPages: How far back a single service is willing to page. Costs nothing in the normal
    ///     case — a second page is only ever requested when the first came back *full*, which an
    ///     idle service never does.
    init(
        client: RenderClient,
        watchlist: WatchlistStore,
        watermarks: EventWatermarkStore,
        now: @escaping @Sendable () -> Date = Date.init,
        concurrency: Int = 4,
        pageLimit: Int = 100,
        maxPages: Int = 3
    ) {
        self.client = client
        self.watchlist = watchlist
        self.watermarks = watermarks
        self.now = now
        self.concurrency = concurrency
        self.pageLimit = pageLimit
        self.maxPages = maxPages
    }

    /// Checks every watched service and returns what broke, oldest first.
    ///
    /// Never throws. One service's failure — a 404 on a deleted service, a rate limit, a dead
    /// network — must not suppress another service's alert, so each is caught and reported as
    /// "nothing new", leaving that service's watermark where it was so the next wake re-examines
    /// the same window.
    ///
    /// Cancellation — a background wake running out of time — takes the same route: in-flight
    /// requests throw and are caught as "nothing new", no further services are started, and
    /// whatever was already confirmed is returned. Only the services that actually answered move
    /// their watermarks, so nothing is stepped over unread.
    func poll() async -> [FailureAlert] {
        let services = watchlist.watched
        watermarks.prune(keeping: Set(services.map(\.id)))
        guard !services.isEmpty else { return [] }

        var alerts: [FailureAlert] = []
        var remaining = services[...]

        await withTaskGroup(of: Outcome?.self) { group in
            for service in remaining.prefix(concurrency) {
                group.addTask { await self.check(service) }
            }
            remaining = remaining.dropFirst(concurrency)

            while let outcome = await group.next() {
                // Starting another service after the deadline has passed only buys a request that
                // fails and a watermark that stays put. Drain what's running and stop.
                if let next = remaining.first, !Task.isCancelled {
                    remaining = remaining.dropFirst()
                    group.addTask { await self.check(next) }
                }
                guard let outcome else { continue }
                alerts.append(contentsOf: outcome.alerts)
                // Advance only on a reply. Recording progress through a window that was never
                // read is how a failure gets silently skipped.
                var watermark = watermarks[outcome.serviceID] ?? EventWatermark(lastSeen: outcome.examinedFrom)
                watermark.advance(over: outcome.examined)
                watermarks[outcome.serviceID] = watermark
            }
        }

        return alerts.sorted { $0.occurredAt < $1.occurredAt }
    }

    // MARK: - One service

    private struct Outcome: Sendable {
        let serviceID: String
        let examinedFrom: Date
        let examined: [ServiceEvent]
        let alerts: [FailureAlert]
    }

    private func check(_ service: WatchedService) async -> Outcome? {
        guard let watermark = watermarks[service.id] else {
            // First sighting. Start the clock rather than reach back an arbitrary distance: turning
            // watching on should not announce something that broke and was already dealt with.
            watermarks.begin(serviceID: service.id, at: now())
            return nil
        }

        let events: [ServiceEvent]
        do {
            events = try await fetchEvents(serviceID: service.id, since: watermark.lastSeen)
        } catch {
            return nil
        }

        let fresh = events.filter { !watermark.hasSeen($0.id) }
        var alerts = fresh
            .filter { Self.selfDescribingFailures.contains($0.type) }
            .map { event in
                FailureAlert(
                    id: event.id,
                    serviceID: service.id,
                    ownerID: service.ownerID,
                    serviceName: service.name,
                    summary: Self.summary(event.type.displayName, cause: event.details.failure?.summary),
                    occurredAt: event.timestamp,
                    eventID: event.id
                )
            }

        let deploysEnded = fresh.filter { $0.type == .deployEnded }
        // An event that names its deploy's outcome answers for itself — and for *that* deploy, not
        // whichever is newest. Only events without one fall back to the deploy list.
        alerts.append(contentsOf: Self.deployAlerts(from: deploysEnded, for: service))

        if let deployEnded = deploysEnded.first(where: { $0.details.deployStatus == nil }) {
            do {
                if let alert = try await deployFailureAlert(for: service, endedAt: deployEnded.timestamp),
                   !alerts.contains(where: { $0.id == alert.id }) {
                    alerts.append(alert)
                }
            } catch {
                // The events request answered but the deploy lookup didn't, so whether that deploy
                // failed is still unknown. Report nothing and leave the watermark alone: advancing
                // past a `deploy_ended` whose outcome was never learned loses the alert for good,
                // and a cancelled wake makes that the *likely* path rather than a rare one.
                return nil
            }
        }

        return Outcome(
            serviceID: service.id,
            examinedFrom: watermark.lastSeen,
            examined: events,
            alerts: alerts
        )
    }

    /// Every event since `watermark`, newest first.
    ///
    /// **Why this pages at all.** The endpoint returns the *newest* `limit` events in the window, so
    /// a single request that comes back full has silently dropped the window's older end — and since
    /// the watermark then advances to the newest timestamp read, those events are stepped over for
    /// good. The direction matters: what gets dropped is the start of the incident, and what's kept
    /// is its aftermath. A deploy storm or a crash-looping instance clears 100 events easily.
    ///
    /// Paging is backwards by `endTime` rather than by cursor, for the reason ``ServiceEventsStore``
    /// documents: the response envelope can't carry a cursor. Bounded by `maxPages`, because a
    /// background wake can't spend unbounded requests on one service; past that the truncation is
    /// back, now needing `pageLimit * maxPages` events since the last wake to bite.
    private func fetchEvents(serviceID: String, since watermark: Date) async throws -> [ServiceEvent] {
        var collected: [ServiceEvent] = []
        var seen: Set<String> = []
        var endTime: Date?

        for _ in 0 ..< maxPages {
            let page = try await client.api
                .listEvents(
                    path: .init(serviceId: serviceID),
                    query: .init(startTime: watermark, endTime: endTime, limit: pageLimit)
                )
                .ok.body.json
                .map { ServiceEvent($0.event) }

            let fresh = page.filter { seen.insert($0.id).inserted }
            collected.append(contentsOf: fresh)

            // Two stops, same as the timeline's: a short page is the end of the window, and an
            // all-duplicates page means every event in it shares one timestamp, so `endTime` can't
            // move and asking again would return the same page forever.
            guard page.count >= pageLimit, !fresh.isEmpty, let oldest = page.last?.timestamp else { break }
            // Inclusive, so the boundary comes back; `seen` removes it.
            endTime = oldest
        }

        return collected
    }

    /// `"Deploy failed"`, or `"Deploy failed: Out of memory (512Mi limit)"` when the cause is known.
    static func summary(_ what: String, cause: String?) -> String {
        cause.map { "\(what): \($0)" } ?? what
    }

    /// Alerts for the `deploy_ended` events whose details say how their deploy ended.
    ///
    /// Keyed on the deploy, like the fallback below, so two events about one deploy report once —
    /// and so a deploy reported here and by the fallback in the same window can't post twice.
    static func deployAlerts(from events: [ServiceEvent], for service: WatchedService) -> [FailureAlert] {
        var seen: Set<String> = []
        return events.compactMap { event in
            let details = event.details
            guard details.deployStatus == "failed" else { return nil }
            let key = details.deployID ?? event.id
            guard seen.insert(key).inserted else { return nil }
            return FailureAlert(
                id: "deploy-\(key)",
                serviceID: service.id,
                ownerID: service.ownerID,
                serviceName: service.name,
                summary: summary(
                    details.failedBuildID != nil ? "Build failed" : "Deploy failed",
                    cause: details.failure?.summary
                ),
                occurredAt: event.timestamp,
                eventID: event.id
            )
        }
    }

    /// Resolves a `deploy_ended` event whose details *don't* carry a status into an alert, or `nil`
    /// if that deploy succeeded.
    ///
    /// Throws rather than swallowing a failed lookup, so the caller can tell "that deploy was fine"
    /// from "couldn't find out" — the two have opposite consequences for the watermark.
    ///
    /// Every `deploy_ended` seen in real data carries `deployStatus`, so this is a fallback for
    /// events that don't — the status then comes from the deploy list instead.
    ///
    /// **Known imprecision:** this reads the *newest* deploy, which is only the one that just ended
    /// if nothing has started since. A deploy that fails and is immediately redeployed will report
    /// the redeploy's status. Erring toward the newest state is the right way round for an alert —
    /// it means never shouting about a failure that has already been superseded.
    private func deployFailureAlert(for service: WatchedService, endedAt: Date) async throws -> FailureAlert? {
        guard let deploy = try await DeploysStore.latestDeploy(client: client, serviceID: service.id),
              let status = deploy.status,
              status.isFailure
        else { return nil }

        return FailureAlert(
            // Keyed on the deploy, not the event: a window holding two `deploy_ended` events
            // resolves to one deploy, and should say so once.
            id: "deploy-\(deploy.id)",
            serviceID: service.id,
            ownerID: service.ownerID,
            serviceName: service.name,
            summary: status.displayName,
            occurredAt: deploy.finishedAt ?? endedAt
        )
    }
}
