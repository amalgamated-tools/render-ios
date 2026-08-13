/// The lifecycle actions the Postgres detail screen can take. Same contract as `ServiceAction`:
/// each case carries its own confirmation copy, because suspend and restart are one row apart in
/// the menu and the wording is the safety mechanism.
enum PostgresAction: Identifiable, Hashable {
    case restart
    case failover
    case suspend
    case resume

    var id: String {
        switch self {
        case .restart: "restart"
        case .failover: "failover"
        case .suspend: "suspend"
        case .resume: "resume"
        }
    }

    var title: String {
        switch self {
        case .restart: "Restart"
        case .failover: "Fail Over"
        case .suspend: "Suspend"
        case .resume: "Resume"
        }
    }

    var systemImage: String {
        switch self {
        case .restart: "arrow.clockwise"
        case .failover: "arrow.triangle.swap"
        case .suspend: "pause.circle"
        case .resume: "play.circle"
        }
    }

    /// "Destructive" here means user-visible impact — dropped connections — not irreversibility.
    var isDestructive: Bool {
        switch self {
        case .restart, .failover, .suspend: true
        case .resume: false
        }
    }

    func confirmationTitle(databaseName: String) -> String {
        switch self {
        case .restart: "Restart \(databaseName)?"
        case .failover: "Fail over \(databaseName)?"
        case .suspend: "Suspend \(databaseName)?"
        case .resume: "Resume \(databaseName)?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .restart:
            "Restarts the database. Expect a brief interruption while connections re-establish."
        case .failover:
            "Promotes the standby to primary. Connections drop briefly while the failover completes."
        case .suspend:
            "Takes the database offline until you resume it. Connected services lose their connections immediately."
        case .resume:
            "Brings the database back online."
        }
    }

    /// Shown in the banner after the call succeeds. Phrased as "requested" because all four
    /// endpoints answer 202 — Render accepted the intent, the work happens after.
    var successMessage: String {
        switch self {
        case .restart: "Restart requested."
        case .failover: "Failover requested."
        case .suspend: "Suspend requested."
        case .resume: "Resume requested."
        }
    }
}
