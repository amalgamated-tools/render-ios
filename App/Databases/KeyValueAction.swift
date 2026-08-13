/// The lifecycle actions the Key Value detail screen can take. Suspend and resume are all the API
/// offers — there is no restart endpoint for Key Value instances.
enum KeyValueAction: Identifiable, Hashable {
    case suspend
    case resume

    var id: String {
        switch self {
        case .suspend: "suspend"
        case .resume: "resume"
        }
    }

    var title: String {
        switch self {
        case .suspend: "Suspend"
        case .resume: "Resume"
        }
    }

    var systemImage: String {
        switch self {
        case .suspend: "pause.circle"
        case .resume: "play.circle"
        }
    }

    /// "Destructive" here means user-visible impact — dropped connections — not irreversibility.
    var isDestructive: Bool {
        switch self {
        case .suspend: true
        case .resume: false
        }
    }

    func confirmationTitle(instanceName: String) -> String {
        switch self {
        case .suspend: "Suspend \(instanceName)?"
        case .resume: "Resume \(instanceName)?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .suspend:
            "Takes the instance offline until you resume it. Connected services lose their connections immediately."
        case .resume:
            "Brings the instance back online."
        }
    }

    /// Shown in the banner after the call succeeds. Phrased as "requested" because both endpoints
    /// answer 202 — Render accepted the intent, the work happens after.
    var successMessage: String {
        switch self {
        case .suspend: "Suspend requested."
        case .resume: "Resume requested."
        }
    }
}
