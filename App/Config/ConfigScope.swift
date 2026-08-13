import Foundation

/// Whose configuration a screen is showing: one service's, or an env group's shared with several.
///
/// The env var and secret file screens are the same screens either way — same masking, same
/// key-at-a-time writes, same editors — but two sentences have to differ, and both are claims about
/// when a change actually reaches a running service. Keeping them here means neither screen can get
/// one right and the other wrong.
enum ConfigScope: Sendable, Hashable {
    case service
    /// A group feeds every service linked to it, and the count is what makes the promise specific.
    case envGroup(linkedServiceCount: Int)

    /// What a successful write says about when it takes effect.
    ///
    /// Phase 5a measured that an API config write does **not** deploy: the configuration changes
    /// immediately and the running instances keep the old value until something deploys them. That's
    /// true of a group write too, only multiplied — so a group says how many services are waiting
    /// rather than implying the one you came from is the only one affected.
    var takesEffectNote: String {
        switch self {
        case .service:
            "It takes effect on the next deploy."
        case .envGroup(let count) where count == 0:
            "No services are linked to this group yet."
        case .envGroup(let count):
            "It takes effect on the next deploy of the \(count) linked service\(count == 1 ? "" : "s")."
        }
    }

    /// Why the list might legitimately be empty. On a service this has to mention env groups, since
    /// "no variables" is otherwise misread as "nothing is configured" by someone whose variables all
    /// live in a group.
    var emptyEnvVarsDescription: String {
        switch self {
        case .service:
            "This service has none set directly. Variables from a linked environment group aren't listed here."
        case .envGroup:
            "This group has no variables yet. Anything added here reaches every service linked to it."
        }
    }

    var emptySecretFilesDescription: String {
        switch self {
        case .service:
            "This service has none set directly. Files from a linked environment group aren't listed here."
        case .envGroup:
            "This group has no secret files yet. Anything added here reaches every service linked to it."
        }
    }
}
