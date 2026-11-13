import RenderAPI
import SwiftUI

/// A service's event timeline: what Render did to this service and when.
///
/// Rows are type + time only — see `ServiceEvent` for why the payload's `details` can't be trusted.
/// Even so, the sequence is what matters on call: "server failed, deploy started, build failed" is a
/// story you can act on.
struct ServiceEventsView: View {
    @State private var store: ServiceEventsStore

    init(client: RenderClient, serviceID: String) {
        _store = State(initialValue: ServiceEventsStore(client: client, serviceID: serviceID))
    }

    var body: some View {
        List {
            ForEach(store.events) { event in
                HStack(spacing: 12) {
                    Image(systemName: event.type.systemImage)
                        .foregroundStyle(event.type.tint)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.type.displayName)
                            .font(.subheadline)
                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if store.hasMore && store.errorMessage == nil {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .listRowSeparator(.hidden)
                .onAppear { Task { await store.loadNextPage() } }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Events")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { if store.events.isEmpty { await store.refresh() } }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let message = store.errorMessage, store.events.isEmpty {
            ErrorStateView(subject: "events", message: message) { await store.refresh() }
        } else if store.events.isEmpty && store.isLoading {
            ProgressView()
        } else if store.events.isEmpty {
            ContentUnavailableView(
                "No Events",
                systemImage: "list.bullet.rectangle",
                description: Text("Nothing has happened to this service yet.")
            )
        }
    }
}

/// Display mapping for all 45 event types. Grouped by what the reader cares about — did something
/// break, is something moving, or is this just bookkeeping — rather than one bespoke label each.
extension Components.Schemas.ServiceEventWithCursor.EventPayload._TypePayload {
    var displayName: String {
        switch self {
        case .artifactFetchFailed: "Artifact fetch failed"
        case .artifactSourceChanged: "Artifact source changed"
        case .autoscalingConfigChanged: "Autoscaling config changed"
        case .autoscalingEnded: "Autoscaling ended"
        case .autoscalingStarted: "Autoscaling started"
        case .autoDeployDisabled: "Auto-deploy disabled"
        case .autoDeployEnabled: "Auto-deploy enabled"
        case .branchDeleted: "Branch deleted"
        case .buildEnded: "Build ended"
        case .buildStarted: "Build started"
        case .commitIgnored: "Commit ignored"
        case .cronJobRunEnded: "Cron run ended"
        case .cronJobRunStarted: "Cron run started"
        case .deployEnded: "Deploy ended"
        case .deployStarted: "Deploy started"
        case .diskCreated: "Disk created"
        case .diskUpdated: "Disk updated"
        case .diskDeleted: "Disk deleted"
        case .diskSnapshotRestored: "Disk snapshot restored"
        case .serviceDiskUsageHigh: "Disk usage high"
        case .serviceDiskUsageRecovered: "Disk usage recovered"
        case .imagePullFailed: "Image pull failed"
        case .initialDeployHookEnded: "Initial deploy hook ended"
        case .initialDeployHookStarted: "Initial deploy hook started"
        case .instanceCountChanged: "Instance count changed"
        case .jobRunEnded: "Job run ended"
        case .maintenanceModeEnabled: "Maintenance mode enabled"
        case .maintenanceModeUriUpdated: "Maintenance page updated"
        case .maintenanceEnded: "Maintenance ended"
        case .maintenanceStarted: "Maintenance started"
        case .pipelineMinutesExhausted: "Pipeline minutes exhausted"
        case .planChanged: "Plan changed"
        case .preDeployEnded: "Pre-deploy ended"
        case .preDeployStarted: "Pre-deploy started"
        case .serverAvailable: "Server available"
        case .serverFailed: "Server failed"
        case .serverHardwareFailure: "Server hardware failure"
        case .serverRestarted: "Server restarted"
        case .serviceResumed: "Service resumed"
        case .serviceSuspended: "Service suspended"
        case .suspenderAdded: "Suspender added"
        case .suspenderRemoved: "Suspender removed"
        case .zeroDowntimeRedeployEnded: "Zero-downtime redeploy ended"
        case .zeroDowntimeRedeployStarted: "Zero-downtime redeploy started"
        }
    }

    var systemImage: String {
        switch self {
        case .artifactFetchFailed, .imagePullFailed, .serverFailed, .serverHardwareFailure,
             .pipelineMinutesExhausted:
            "exclamationmark.octagon.fill"
        case .buildStarted, .buildEnded:
            "hammer"
        case .deployStarted, .deployEnded, .zeroDowntimeRedeployStarted, .zeroDowntimeRedeployEnded,
             .initialDeployHookStarted, .initialDeployHookEnded, .preDeployStarted, .preDeployEnded:
            "shippingbox"
        case .cronJobRunStarted, .cronJobRunEnded, .jobRunEnded:
            "clock.arrow.circlepath"
        case .serverAvailable:
            "checkmark.circle.fill"
        case .serverRestarted:
            "arrow.clockwise"
        case .serviceSuspended, .suspenderAdded:
            "pause.circle"
        case .serviceResumed, .suspenderRemoved:
            "play.circle"
        case .autoscalingStarted, .autoscalingEnded, .autoscalingConfigChanged, .instanceCountChanged:
            "arrow.up.arrow.down"
        case .maintenanceStarted, .maintenanceEnded, .maintenanceModeEnabled, .maintenanceModeUriUpdated:
            "wrench.and.screwdriver"
        case .diskCreated, .diskUpdated, .diskDeleted, .diskSnapshotRestored,
             .serviceDiskUsageHigh, .serviceDiskUsageRecovered:
            "externaldrive"
        case .branchDeleted, .commitIgnored, .autoDeployDisabled, .autoDeployEnabled,
             .artifactSourceChanged, .planChanged:
            "gearshape"
        }
    }

    /// Red for "look at this", green for recovery, orange for capacity/maintenance, gray otherwise.
    var tint: Color {
        switch self {
        case .artifactFetchFailed, .imagePullFailed, .serverFailed, .serverHardwareFailure,
             .pipelineMinutesExhausted, .serviceSuspended, .suspenderAdded:
            .red
        case .serverAvailable, .serviceResumed, .suspenderRemoved, .serviceDiskUsageRecovered:
            .green
        case .serviceDiskUsageHigh,
             .autoscalingStarted, .autoscalingEnded, .instanceCountChanged, .maintenanceStarted,
             .maintenanceEnded, .maintenanceModeEnabled, .maintenanceModeUriUpdated:
            .orange
        case .buildStarted, .buildEnded, .deployStarted, .deployEnded, .preDeployStarted,
             .preDeployEnded, .zeroDowntimeRedeployStarted, .zeroDowntimeRedeployEnded,
             .initialDeployHookStarted, .initialDeployHookEnded, .serverRestarted:
            .blue
        case .cronJobRunStarted, .cronJobRunEnded, .jobRunEnded, .diskCreated, .diskUpdated,
             .diskDeleted, .diskSnapshotRestored, .branchDeleted, .commitIgnored, .autoDeployDisabled, .autoDeployEnabled,
             .artifactSourceChanged, .planChanged, .autoscalingConfigChanged:
            .secondary
        }
    }
}
