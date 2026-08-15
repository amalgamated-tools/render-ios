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
/// types worth alerting on would multiply the request count by seven rather than divide it. One
/// unfiltered request per service since its watermark is the cheapest correct thing available, and
/// on an idle service it comes back empty.
@MainActor
final class FailureWatcher {
    /// Event types where the type alone is the alert.
    ///
    /// The rest of the timeline needs `event.details` to mean anything, and `details` cannot be read
    /// — see ``ServiceEvent``. `deploy_ended` is the one ambiguous type worth the extra request, and
    /// it's handled separately below; `build_ended` is deliberately absent because a failed build
    /// always produces a `deploy_ended` too, and alerting on both would double-report one failure.
    static let selfDescribingFailures: Set<Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload> = [
        .serverFailed,
        .serverHardwareFailure,
        .imagePullFailed,
        .artifactFetchFailed,
        .commitIgnored,
        .pipelineMinutesExhausted,
        .serviceSuspended,
    ]

    private let client: RenderClient
    private let watchlist: WatchlistStore
    private let watermarks: EventWatermarkStore
    private let now: @Sendable () -> Date
    private let concurrency: Int
    private let pageLimit: Int

    /// - Parameters:
    ///   - concurrency: How many services are checked at once. `RetryMiddleware` already handles
    ///     429s, but a background wake has seconds to work with — better not to provoke a retry.
    ///   - pageLimit: The endpoint caps `limit` at 100. A watched service that produced more than
    ///     this many events since the last wake has bigger problems than a missed notification.
    init(
        client: RenderClient,
        watchlist: WatchlistStore,
        watermarks: EventWatermarkStore,
        now: @escaping @Sendable () -> Date = Date.init,
        concurrency: Int = 4,
        pageLimit: Int = 100
    ) {
        self.client = client
        self.watchlist = watchlist
        self.watermarks = watermarks
        self.now = now
        self.concurrency = concurrency
        self.pageLimit = pageLimit
    }

    /// Checks every watched service and returns what broke, oldest first.
    ///
    /// Never throws. One service's failure — a 404 on a deleted service, a rate limit, a dead
    /// network — must not suppress another service's alert, so each is caught and reported as
    /// "nothing new", leaving that service's watermark where it was so the next wake re-examines
    /// the same window.
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
                if let next = remaining.first {
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
            events = try await client.api
                .listEvents(
                    path: .init(serviceId: service.id),
                    query: .init(startTime: watermark.lastSeen, limit: pageLimit)
                )
                .ok.body.json
                .map { ServiceEvent($0.event) }
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
                    summary: event.type.displayName,
                    occurredAt: event.timestamp
                )
            }

        if let deployEnded = fresh.first(where: { $0.type == .deployEnded }),
           let alert = await deployFailureAlert(for: service, endedAt: deployEnded.timestamp) {
            alerts.append(alert)
        }

        return Outcome(
            serviceID: service.id,
            examinedFrom: watermark.lastSeen,
            examined: events,
            alerts: alerts
        )
    }

    /// Resolves a `deploy_ended` event into an alert, or `nil` if that deploy succeeded.
    ///
    /// The event says a deploy finished but not *which* deploy or *how* — that lives in
    /// `event.details`, which the generated union can't be trusted to decode (see ``ServiceEvent``).
    /// So the status comes from the deploy list instead, which decodes cleanly.
    ///
    /// **Known imprecision:** this reads the *newest* deploy, which is only the one that just ended
    /// if nothing has started since. A deploy that fails and is immediately redeployed will report
    /// the redeploy's status. Erring toward the newest state is the right way round for an alert —
    /// it means never shouting about a failure that has already been superseded — and the accurate
    /// alternative needs a spec patch to make `details` readable.
    private func deployFailureAlert(for service: WatchedService, endedAt: Date) async -> FailureAlert? {
        guard let deploy = try? await DeploysStore.latestDeploy(client: client, serviceID: service.id),
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
