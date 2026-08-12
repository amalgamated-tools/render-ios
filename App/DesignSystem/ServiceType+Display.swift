import RenderAPI
import SwiftUI

/// Phase 1's scoped-down status design system: how a service *type* and its suspended flag render.
///
/// The full 11-value `deployStatus` color mapping lands in Phase 2 with the detail screen — the
/// `/services` list payload carries no deploy status, so there is nothing to color here yet.
extension Components.Schemas.ServiceType {
    /// A short, human label. The generated raw values are snake_case (`web_service`).
    var displayName: String {
        switch self {
        case .webService: "Web Service"
        case .staticSite: "Static Site"
        case .privateService: "Private Service"
        case .backgroundWorker: "Background Worker"
        case .cronJob: "Cron Job"
        }
    }

    /// SF Symbol that reads at a glance in a dense list.
    var systemImage: String {
        switch self {
        case .webService: "globe"
        case .staticSite: "doc.richtext"
        case .privateService: "lock.shield"
        case .backgroundWorker: "gearshape.2"
        case .cronJob: "clock.arrow.circlepath"
        }
    }

    /// Tint for the type glyph. Deliberately not a *health* signal — it only distinguishes types.
    var accent: Color {
        switch self {
        case .webService: .blue
        case .staticSite: .teal
        case .privateService: .indigo
        case .backgroundWorker: .purple
        case .cronJob: .orange
        }
    }
}
