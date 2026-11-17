import Foundation
import Observation
import RenderAPI

/// A workspace member's role. Render answers in uppercase, and may add roles this build doesn't
/// know (see `Scripts/workspace-quirks.py`), which read as `.other`.
enum MemberRole: Hashable, Sendable {
    case admin
    case developer
    case contributor
    case billing
    case viewer
    case other(String)

    init(raw: String) {
        switch raw.uppercased() {
        case "ADMIN": self = .admin
        case "DEVELOPER": self = .developer
        case "WORKSPACE_CONTRIBUTOR": self = .contributor
        case "WORKSPACE_BILLING": self = .billing
        case "WORKSPACE_VIEWER": self = .viewer
        default: self = .other(raw)
        }
    }

    /// The roles a member can be given, most access first.
    static let assignable: [MemberRole] = [.admin, .developer, .contributor, .billing, .viewer]

    var displayName: String {
        switch self {
        case .admin: "Admin"
        case .developer: "Developer"
        case .contributor: "Contributor"
        case .billing: "Billing"
        case .viewer: "Viewer"
        case .other(let raw): raw.replacingOccurrences(of: "WORKSPACE_", with: "").replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// The value the PATCH request takes. Nil for a role this build doesn't know, which it never sends.
    var requestValue: Components.Schemas.TeamMemberRole? {
        switch self {
        case .admin: .admin
        case .developer: .developer
        case .contributor: .workspaceContributor
        case .billing: .workspaceBilling
        case .viewer: .workspaceViewer
        case .other: nil
        }
    }
}

struct WorkspaceMember: Identifiable, Hashable, Sendable {
    var id: String { userID }
    let userID: String
    let name: String
    let email: String
    let role: MemberRole
    /// False when Render reports the member as inactive, such as an invite not yet accepted.
    let isActive: Bool
    let isMFAEnabled: Bool

    init(userID: String, name: String, email: String, role: MemberRole, isActive: Bool, isMFAEnabled: Bool) {
        self.userID = userID
        self.name = name
        self.email = email
        self.role = role
        self.isActive = isActive
        self.isMFAEnabled = isMFAEnabled
    }

    init(_ member: Components.Schemas.TeamMember) {
        self.init(
            userID: member.userId, name: member.name, email: member.email, role: MemberRole(raw: member.role),
            isActive: member.status.lowercased() != "inactive", isMFAEnabled: member.mfaEnabled
        )
    }
}

/// The workspace from `GET /owners/{id}`.
struct WorkspaceSummary: Hashable, Sendable {
    let id: String
    let name: String
    let email: String
    let isTeam: Bool
    let ipAllowListCount: Int
    /// Only reported for a personal workspace.
    let isTwoFactorEnabled: Bool?
}

/// A workspace's details and members, and changing a member's role or removing them.
///
/// The signed-in user can't change their own role or remove themselves from here: from a phone, one
/// tap could lock them out of the workspace, so those rows offer no actions.
///
/// What the live API showed: an unknown role answers 400 "invalid role", an unknown member 404, and
/// setting a role a member already has answers 200 with the member.
@MainActor
@Observable
final class WorkspaceMembersStore {
    private(set) var workspace: WorkspaceSummary?
    /// Admins first, then by name.
    private(set) var members: [WorkspaceMember] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var membersErrorMessage: String?
    /// The member being changed or removed, while that request is in flight.
    private(set) var writeInFlight: String?
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    private let client: RenderClient
    let ownerID: String
    /// Bumped by every load and by every write, when it starts and when it ends, so a refresh that
    /// overlaps a write can't put back what the write changed.
    private var generation = 0

    init(client: RenderClient, ownerID: String) {
        self.client = client
        self.ownerID = ownerID
    }

    /// Whether `member` can be changed by the signed-in user. Nil `currentUserID` means it isn't
    /// known yet, so nothing can be.
    func canManage(_ member: WorkspaceMember, currentUserID: String?) -> Bool {
        guard let currentUserID else { return false }
        return member.userID != currentUserID
    }

    func load() async {
        generation += 1
        let current = generation
        let client = client
        let ownerID = ownerID
        async let ownerAttempt: Result<WorkspaceSummary, any Error> = {
            do {
                let owner = try await client.api.retrieveOwner(path: .init(ownerId: ownerID)).ok.body.json
                return .success(WorkspaceSummary(
                    id: owner.id, name: owner.name, email: owner.email, isTeam: owner._type == .team,
                    ipAllowListCount: owner.ipAllowList?.count ?? 0, isTwoFactorEnabled: owner.twoFactorAuthEnabled
                ))
            } catch {
                return .failure(error)
            }
        }()

        let membersResult: Result<[WorkspaceMember], any Error>
        do {
            let listed = try await client.api.retrieveOwnerMembers(path: .init(ownerId: ownerID)).ok.body.json
            membersResult = .success(listed.map(WorkspaceMember.init))
        } catch {
            membersResult = .failure(error)
        }
        let owner = await ownerAttempt
        guard current == generation else { return }

        switch owner {
        case .success(let summary):
            workspace = summary
            errorMessage = nil
        case .failure(let error):
            errorMessage = Self.message(for: error)
        }
        switch membersResult {
        case .success(let listed):
            members = Self.sorted(listed)
            membersErrorMessage = nil
        case .failure(let error):
            membersErrorMessage = Self.message(for: error)
        }
        hasLoaded = true
    }

    /// Returns whether Render accepted the change.
    @discardableResult
    func changeRole(of member: WorkspaceMember, to role: MemberRole, currentUserID: String?) async -> Bool {
        guard writeInFlight == nil, canManage(member, currentUserID: currentUserID),
              role != member.role, let requestRole = role.requestValue
        else { return false }
        beginWrite(member)
        defer { endWrite() }
        do {
            let updated = try await client.api.updateWorkspaceMember(
                path: .init(ownerId: ownerID, userId: member.userID),
                body: .json(.init(role: requestRole))
            ).ok.body.json
            let changed = WorkspaceMember(updated)
            members = Self.sorted(members.map { $0.userID == changed.userID ? changed : $0 })
            actionResult = ActionResult(message: "\(Self.label(changed)) is now \(changed.role.displayName).", isFailure: false)
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    /// Returns whether Render removed them.
    @discardableResult
    func remove(_ member: WorkspaceMember, currentUserID: String?) async -> Bool {
        guard writeInFlight == nil, canManage(member, currentUserID: currentUserID) else { return false }
        beginWrite(member)
        defer { endWrite() }
        do {
            try await client.api.removeWorkspaceMember(
                path: .init(ownerId: ownerID, userId: member.userID)
            ).expectSuccess()
            members.removeAll { $0.userID == member.userID }
            actionResult = ActionResult(message: "Removed \(Self.label(member)).", isFailure: false)
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    // MARK: - Internals

    private func beginWrite(_ member: WorkspaceMember) {
        writeInFlight = member.userID
        actionResult = nil
        generation += 1
    }

    private func endWrite() {
        generation += 1
        writeInFlight = nil
    }

    private static func label(_ member: WorkspaceMember) -> String {
        member.name.isEmpty ? member.email : member.name
    }

    private static func sorted(_ members: [WorkspaceMember]) -> [WorkspaceMember] {
        members.sorted {
            if ($0.role == .admin) != ($1.role == .admin) { return $0.role == .admin }
            return label($0).localizedStandardCompare(label($1)) == .orderedAscending
        }
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
