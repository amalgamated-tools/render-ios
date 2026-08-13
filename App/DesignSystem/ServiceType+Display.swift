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

/// The spec has a *second* service type enum with its own vocabulary (`web`, `pserv`, `static`), used
/// where a service is referred to rather than described — env group links being the first place the app
/// meets one. Mapping it onto the full enum rather than giving it its own labels means a linked service
/// looks exactly like the same service in the service list.
extension Components.Schemas.ServiceTypeShort {
    var full: Components.Schemas.ServiceType {
        switch self {
        case ._static: .staticSite
        case .web: .webService
        case .pserv: .privateService
        case .worker: .backgroundWorker
        case .cron: .cronJob
        }
    }

    var displayName: String { full.displayName }
    var systemImage: String { full.systemImage }
    var accent: Color { full.accent }
}
