import Foundation
import Observation
import RenderAPI

/// One login role on a Render Postgres database, from `GET /postgres/{id}/credentials`.
struct PostgresUser: Identifiable, Hashable, Sendable {
    var id: String { username }
    let username: String
    /// The user the database's connection details are for. Render makes each new user the default.
    let isDefault: Bool
    let createdAt: Date?
    let openConnections: Int

    /// `createdAt` arrives as a plain string with up to nine fractional digits
    /// (`2026-11-17T01:48:27.490331884Z`), more than `ISO8601DateFormatter` reads, so it's cut to
    /// milliseconds first.
    static func parseDate(_ raw: String?) -> Date? {
        guard var raw else { return nil }
        if let dot = raw.firstIndex(of: "."), let zone = raw[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = raw[raw.index(after: dot)..<zone].prefix(3)
            raw = String(raw[..<dot]) + "." + fraction.padding(toLength: 3, withPad: "0", startingAt: 0) + String(raw[zone...])
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

/// Lists, adds and deletes a Postgres database's users, which is how its credentials are rotated:
/// add a user (it becomes the default, and the connection details switch to it), move clients over,
/// then delete the old one.
///
/// What the live API showed, which shaped this:
/// - Usernames may contain only `a-z`, `0-9` and `_`, and must be new. Both are checked here first.
/// - The default user can't be deleted ("refusing to delete default user").
/// - A create answers `201` and a delete `204`, where the spec says `202` and `200`; see
///   `NoContentWrite`.
/// - These endpoints allow about one request every few seconds. Render answers a faster one with
///   `429` and `Retry-After`, which `RetryMiddleware` waits out.
@MainActor
@Observable
final class PostgresUsersStore {
    /// Default user first, then newest first.
    private(set) var users: [PostgresUser] = []
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    /// The username being added or deleted, while that request is in flight.
    private(set) var writeInFlight: String?
    private(set) var actionResult: ActionResult?

    struct ActionResult: Identifiable, ActionOutcome {
        let id = UUID()
        let message: String
        let isFailure: Bool
    }

    /// Postgres caps identifiers at 63 bytes.
    static let maxUsernameLength = 63

    private let client: RenderClient
    let postgresID: String

    init(client: RenderClient, postgresID: String) {
        self.client = client
        self.postgresID = postgresID
    }

    var defaultUser: PostgresUser? { users.first(where: \.isDefault) }

    /// Why `username` can't be added, or nil when it can.
    func validationMessage(forNewUsername username: String) -> String? {
        if username.isEmpty { return "Enter a username." }
        if username.count > Self.maxUsernameLength { return "Use \(Self.maxUsernameLength) characters or fewer." }
        if username.contains(where: { !($0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")) }) {
            return "Use only lowercase letters, digits and underscores."
        }
        if users.contains(where: { $0.username == username }) { return "\(username) already exists." }
        return nil
    }

    func load() async {
        do {
            let listed = try await client.api
                .listPostgresUsers(path: .init(postgresId: postgresID))
                .ok.body.json
            users = listed
                .compactMap { user in
                    user.username.map {
                        PostgresUser(
                            username: $0,
                            isDefault: user._default ?? false,
                            createdAt: PostgresUser.parseDate(user.createdAt),
                            openConnections: user.openConnections ?? 0
                        )
                    }
                }
                .sorted {
                    if $0.isDefault != $1.isDefault { return $0.isDefault }
                    return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
                }
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error)
        }
        hasLoaded = true
    }

    /// Adds `username`, which Render makes the new default user. Returns whether Render accepted it.
    @discardableResult
    func add(username: String) async -> Bool {
        guard writeInFlight == nil, validationMessage(forNewUsername: username) == nil else { return false }
        writeInFlight = username
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await client.api.createPostgresUser(
                path: .init(postgresId: postgresID),
                body: .json(.init(username: username))
            ).expectSuccess()
            actionResult = ActionResult(
                message: "Added \(username). It's now the default user, and the connection details use it.",
                isFailure: false
            )
            await load()
            return true
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            return false
        }
    }

    /// Deletes a user that isn't the default. Anything still connecting as it loses access.
    func delete(_ user: PostgresUser) async {
        guard writeInFlight == nil, !user.isDefault else { return }
        writeInFlight = user.username
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            try await client.api.deletePostgresUser(
                path: .init(postgresId: postgresID, username: user.username)
            ).expectSuccess()
            users.removeAll { $0.username == user.username }
            actionResult = ActionResult(message: "Deleted \(user.username).", isFailure: false)
        } catch {
            actionResult = ActionResult(message: Self.message(for: error), isFailure: true)
            await load()
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    private static func message(for error: any Error) -> String {
        RenderError.wrapping(error).errorDescription ?? "Something went wrong."
    }
}
