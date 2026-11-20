import Foundation
import Observation
import RenderAPI

/// One audit log entry: who did what, when, and the details Render recorded.
struct AuditLogEntry: Identifiable, Hashable, Sendable {
    let id: String
    let timestamp: Date
    /// As Render sent it, such as `CreateServerEvent`. May be one this build doesn't know.
    let event: String
    let outcome: Outcome
    /// `user`, `rest_api` or `system`, as Render sent it.
    let actorType: String
    let actorEmail: String?
    let actorID: String?
    /// Extra context, such as the service ID, source IP and user agent, sorted by key.
    let metadata: [(key: String, value: String)]

    /// The entry's `status`. Render sends `success` or `error`; anything else is kept as sent rather
    /// than counted as either.
    enum Outcome: Hashable, Sendable {
        case succeeded
        case failed
        case other(String)

        init(raw: String) {
            switch raw.lowercased() {
            case "success": self = .succeeded
            case "error": self = .failed
            default: self = .other(raw)
            }
        }

        var title: String {
            switch self {
            case .succeeded: "Succeeded"
            case .failed: "Failed"
            case .other(let raw): raw.isEmpty ? "Unknown" : raw.capitalized
            }
        }
    }

    static func == (lhs: AuditLogEntry, rhs: AuditLogEntry) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// `CreateServerEvent` → "Create server", `ChangeOrg2FAEnforcementEvent` → "Change org 2FA enforcement".
    static func displayName(_ event: String) -> String {
        var name = event
        if name.hasSuffix("Event"), name.count > 5 { name.removeLast(5) }
        // Split before an uppercase letter that follows a lowercase one, before the last capital of a
        // run that starts a new word ("2FAEnforcement" → "2FA", "Enforcement"), and before a number
        // that follows a lowercase letter.
        var words: [String] = []
        var current = ""
        let chars = Array(name)
        for (index, char) in chars.enumerated() {
            if !current.isEmpty {
                let previous = chars[index - 1]
                let next = index + 1 < chars.count ? chars[index + 1] : nil
                let startsWord = char.isUppercase
                    && (previous.isLowercase || (previous.isUppercase && next?.isLowercase == true))
                // "Org2FA": a number after a lowercase letter starts "2FA".
                let startsNumber = char.isNumber && previous.isLowercase
                if startsWord || startsNumber {
                    words.append(current)
                    current = ""
                }
            }
            current.append(char)
        }
        if !current.isEmpty { words.append(current) }
        // Mixed-case names the rules above split: "OAuth" comes out as "O", "Auth".
        for term in ["OAuth"] {
            var index = 0
            while index + 1 < words.count {
                if words[index] + words[index + 1] == term {
                    words.replaceSubrange(index...index + 1, with: [term])
                }
                index += 1
            }
        }
        return words.enumerated().map { index, word in
            // Leave acronyms such as "2FA" or "IP" as they are.
            let isAcronym = word.count > 1 && word.dropFirst().contains(where: \.isUppercase)
            if isAcronym || index == 0 { return word }
            return word.lowercased()
        }.joined(separator: " ")
    }

    /// Who did it: the email for a person, otherwise the kind of actor. An API key or Render can
    /// carry an email too; it's the key's or account's, so the kind of actor is the useful part.
    var actorDescription: String {
        if actorType == "user" || actorType.isEmpty, let actorEmail, !actorEmail.isEmpty { return actorEmail }
        switch actorType {
        case "rest_api": return "API key"
        case "system": return "Render"
        default: return actorType.isEmpty ? "Unknown" : actorType.capitalized
        }
    }

    var title: String { Self.displayName(event) }
}

extension AuditLogEntry {
    init(_ log: Components.Schemas.AuditLog) {
        self.init(
            id: log.id,
            timestamp: log.timestamp,
            event: log.event,
            outcome: Outcome(raw: log.status),
            actorType: log.actor._type,
            actorEmail: log.actor.email,
            actorID: log.actor.id,
            metadata: log.metadata.additionalProperties.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
        )
    }
}

/// A workspace's or an organization's audit log, newest first, a page at a time. Both return the
/// same entries; an organization's covers it and all of its workspaces.
///
/// Live, the log only reached back about a day in a new workspace, and Render keeps it for a
/// limited time, so the screen says that rather than implying it's complete.
@MainActor
@Observable
final class AuditLogStore {
    private(set) var entries: [AuditLogEntry] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var hasMore: Bool { nextCursor != nil }

    enum Scope: Hashable, Sendable {
        case workspace(ownerID: String)
        /// Read with the organization's own Audit Log API key, which the client must carry.
        case organization(id: String)
    }

    private let client: RenderClient
    let scope: Scope
    private let pageSize: Int
    private var nextCursor: String?
    /// Bumped by each fresh load, so a page requested before it can't land on the new list.
    private var generation = 0

    init(client: RenderClient, scope: Scope, pageSize: Int = 50) {
        self.client = client
        self.scope = scope
        self.pageSize = pageSize
    }

    convenience init(client: RenderClient, ownerID: String, pageSize: Int = 50) {
        self.init(client: client, scope: .workspace(ownerID: ownerID), pageSize: pageSize)
    }

    func load() async {
        generation += 1
        await loadPage(after: nil, generation: generation, replacing: true)
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        await loadPage(after: cursor, generation: generation, replacing: false)
    }

    private func loadPage(after cursor: String?, generation current: Int, replacing: Bool) async {
        let client = client
        let scope = scope
        isLoading = true
        defer { if current == generation { isLoading = false } }
        do {
            let paginator = CursorPaginator(pageSize: pageSize) { cursor, limit in
                try await Self.fetch(client: client, scope: scope, cursor: cursor, limit: limit)
            } unwrap: { envelope in
                (AuditLogEntry(envelope.auditLog), envelope.cursor)
            }
            let page = try await paginator.firstPage(after: cursor)
            guard current == generation else { return }
            let known = replacing ? [] : entries
            entries = known + page.elements.filter { entry in !known.contains { $0.id == entry.id } }
            nextCursor = page.nextCursor
            errorMessage = nil
        } catch {
            guard current == generation else { return }
            errorMessage = Self.describe(error, scope: scope)
        }
        hasLoaded = true
    }

    nonisolated static func fetch(
        client: RenderClient, scope: Scope, cursor: String?, limit: Int
    ) async throws -> [Components.Schemas.AuditLogWithCursor] {
        switch scope {
        case .workspace(let ownerID):
            try await client.api
                .listOwnerAuditLogs(path: .init(ownerId: ownerID), query: .init(cursor: cursor, limit: limit))
                .ok.body.json
        case .organization(let id):
            try await client.api
                .listOrganizationAuditLogs(path: .init(orgId: id), query: .init(cursor: cursor, limit: limit))
                .ok.body.json
        }
    }

    /// For an organization, the key is the usual cause, so say which part Render refused. Live, a
    /// key from another organization got 403 and a workspace ID in place of an organization's got 404.
    nonisolated static func describe(_ error: any Error, scope: Scope) -> String? {
        let renderError = RenderError.wrapping(error)
        guard case .organization(let id) = scope else { return renderError.errorDescription }
        switch renderError {
        case .unauthorized:
            return "Render didn't accept this Audit Log API key. It may have been revoked."
        case .forbidden:
            return "This key can't read \(id)'s audit log. An Audit Log API key only covers the organization it was created in."
        case .notFound:
            return "Render doesn't know an organization with the ID \(id)."
        default:
            return renderError.errorDescription
        }
    }
}
