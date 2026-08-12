import RenderAPI
import SwiftUI

/// The deploy-status half of the status design system, deferred from Phase 1 to here because the
/// `/services` list payload carries no deploy status — the detail screen is the first place one
/// exists to color.
///
/// All 11 spec values are mapped explicitly rather than defaulted, so a new status added upstream
/// shows up as a compile error instead of silently rendering as "fine".
extension Components.Schemas.DeployStatus {
    var displayName: String {
        switch self {
        case .created: "Created"
        case .queued: "Queued"
        case .buildInProgress: "Building"
        case .preDeployInProgress: "Pre-deploy"
        case .updateInProgress: "Deploying"
        case .live: "Live"
        case .deactivated: "Deactivated"
        case .buildFailed: "Build failed"
        case .preDeployFailed: "Pre-deploy failed"
        case .updateFailed: "Deploy failed"
        case .canceled: "Canceled"
        }
    }

    var systemImage: String {
        switch self {
        case .created, .queued: "clock"
        case .buildInProgress: "hammer"
        case .preDeployInProgress: "terminal"
        case .updateInProgress: "arrow.triangle.2.circlepath"
        case .live: "checkmark.circle.fill"
        case .deactivated: "moon.zzz"
        case .buildFailed, .preDeployFailed, .updateFailed: "exclamationmark.octagon.fill"
        case .canceled: "slash.circle"
        }
    }

    /// Green means live, red means a human needs to look, blue means in motion, gray means neither.
    var tint: Color {
        switch self {
        case .live: .green
        case .buildFailed, .preDeployFailed, .updateFailed: .red
        case .buildInProgress, .preDeployInProgress, .updateInProgress: .blue
        case .created, .queued: .orange
        case .deactivated, .canceled: .secondary
        }
    }

    /// True while the deploy is still moving, which is what drives detail-screen polling.
    var isInProgress: Bool {
        switch self {
        case .created, .queued, .buildInProgress, .preDeployInProgress, .updateInProgress: true
        case .live, .deactivated, .buildFailed, .preDeployFailed, .updateFailed, .canceled: false
        }
    }

    var isFailure: Bool {
        switch self {
        case .buildFailed, .preDeployFailed, .updateFailed: true
        case .created, .queued, .buildInProgress, .preDeployInProgress, .updateInProgress, .live,
             .deactivated, .canceled: false
        }
    }
}

/// A small pill showing deploy status. Used in the detail header and in each deploy history row.
struct DeployStatusChip: View {
    let status: Components.Schemas.DeployStatus
    var isCompact = false

    var body: some View {
        Label {
            Text(status.displayName)
        } icon: {
            Image(systemName: status.systemImage)
        }
        .font(isCompact ? .caption.weight(.medium) : .subheadline.weight(.medium))
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(status.tint.opacity(0.12), in: Capsule())
        .accessibilityLabel("Deploy status: \(status.displayName)")
    }
}

extension Components.Schemas.Deploy.TriggerPayload {
    var displayName: String {
        switch self {
        case .api: "API"
        case .blueprintSync: "Blueprint sync"
        case .deployHook: "Deploy hook"
        case .deployedByRender: "Render"
        case .manual: "Manual"
        case .newCommit: "New commit"
        case .rollback: "Rollback"
        case .serviceResumed: "Service resumed"
        case .serviceUpdated: "Service updated"
        case .other: "Other"
        }
    }
}
