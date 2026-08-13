import RenderAPI
import SwiftUI

/// The datastore half of the status design system. Postgres and Key Value share one status enum
/// upstream, so they share one display mapping here.
///
/// All 11 spec values are mapped explicitly rather than defaulted, so a new status added upstream
/// shows up as a compile error instead of silently rendering as "fine".
extension Components.Schemas.DatabaseStatus {
    var displayName: String {
        switch self {
        case .creating: "Creating"
        case .available: "Available"
        case .unavailable: "Unavailable"
        case .configRestart: "Restarting"
        case .suspended: "Suspended"
        case .maintenanceScheduled: "Maintenance scheduled"
        case .maintenanceInProgress: "Maintenance"
        case .recoveryFailed: "Recovery failed"
        case .recoveryInProgress: "Recovering"
        case .updatingInstance: "Updating"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .available: "checkmark.circle.fill"
        case .unavailable, .recoveryFailed: "exclamationmark.octagon.fill"
        case .creating, .configRestart, .recoveryInProgress, .updatingInstance:
            "arrow.triangle.2.circlepath"
        case .maintenanceScheduled, .maintenanceInProgress: "wrench.and.screwdriver"
        case .suspended: "pause.circle"
        case .unknown: "questionmark.circle"
        }
    }

    /// Green means serving, red means a human needs to look, blue means in motion, orange means
    /// deliberately not serving, gray means we can't say.
    var tint: Color {
        switch self {
        case .available: .green
        case .unavailable, .recoveryFailed: .red
        case .creating, .configRestart, .recoveryInProgress, .maintenanceInProgress, .updatingInstance: .blue
        case .maintenanceScheduled, .suspended: .orange
        case .unknown: .secondary
        }
    }

    /// True while the datastore is mid-transition, which is what drives detail-screen polling —
    /// the analogue of `DeployStatus.isInProgress`.
    var isTransitional: Bool {
        switch self {
        case .creating, .configRestart, .recoveryInProgress, .maintenanceInProgress, .updatingInstance: true
        case .available, .unavailable, .suspended, .maintenanceScheduled, .recoveryFailed, .unknown: false
        }
    }
}

/// A small pill showing datastore status. Used in list rows and the detail header.
struct DatabaseStatusChip: View {
    let status: Components.Schemas.DatabaseStatus
    var isCompact = false

    var body: some View {
        StatusChip(
            title: status.displayName,
            systemImage: status.systemImage,
            tint: status.tint,
            isCompact: isCompact,
            isActive: status.isTransitional
        )
        .accessibilityLabel("Status: \(status.displayName)")
    }
}
