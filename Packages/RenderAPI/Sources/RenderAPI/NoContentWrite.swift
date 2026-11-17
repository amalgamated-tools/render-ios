import Foundation

/// A write whose only documented success is `204 No Content` — and which Render may nonetheless answer
/// with a different 2xx.
///
/// **This is the third time the same lie has cost something.** Phase 5a found that
/// `PUT /services/{id}/secret-files/{name}` answers `200` where its spec says `201`. Phase 5b's live pass
/// found that `DELETE /env-groups/{id}/services/{id}` answers **`200`** where its spec says `204` — and
/// because the generated `.noContent` accessor throws on anything undocumented, an unlink that Render had
/// *performed* was reported to the user as "Couldn't reach Render", with the stale row left on screen.
///
/// So the rule is written down once, here, instead of as a switch at each call site: **any 2xx is a
/// success.** A delete has no body worth reading, so there is nothing else to get right.
///
/// Documented non-success cases (`.badRequest`, `.unauthorized`, …) never reach this: `StatusMappingMiddleware`
/// turns a terminal 4xx/5xx into a thrown ``RenderError`` before the generated `Output` is ever built.
public protocol NoContentWrite: Sendable {
    /// The status code when Render answered with something the spec doesn't document, and `nil` when it
    /// answered with the documented success.
    var undocumentedStatusCode: Int? { get }
}

extension NoContentWrite {
    /// Throws unless Render reported success — by the documented status or any other 2xx.
    public func expectSuccess() throws {
        guard let statusCode = undocumentedStatusCode else { return }
        guard (200..<300).contains(statusCode) else {
            throw RenderError.from(statusCode: statusCode, message: nil)
        }
    }
}

// Each conformance is the same three lines; they're written out rather than generated so that a spec
// change which *removes* one of these operations is a compile error rather than dead code.

extension Operations.DeleteEnvVar.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteSecretFile.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteEnvGroupEnvVar.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteEnvGroupSecretFile.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteEnvGroup.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

/// The one measured offender: answers `200`, not the documented `204`.
extension Operations.UnlinkServiceFromEnvGroup.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteCustomDomain.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteHeader.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeleteRoute.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

// Postgres users: the spec documents `202` for a create and `200` for a delete. Live, Render answered
// `201` (body `{}`) and `204`.

extension Operations.CreatePostgresUser.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}

extension Operations.DeletePostgresUser.Output: NoContentWrite {
    public var undocumentedStatusCode: Int? {
        if case .undocumented(let statusCode, _) = self { return statusCode }
        return nil
    }
}
