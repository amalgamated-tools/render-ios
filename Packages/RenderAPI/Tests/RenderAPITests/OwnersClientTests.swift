import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPITestSupport
import Testing

@testable import RenderAPI

/// Exercises the real generated `Client` end to end through the full middleware stack — the only
/// thing stubbed is the transport. `listOwners` is used because `Owner` has a small required set,
/// so a decodable fixture stays readable (unlike `Service`, whose `serviceDetails` oneOf is heavy).
@Suite("Owners client")
struct OwnersClientTests {
    private func owner(_ n: Int) -> String {
        #"{"id":"own-\#(n)","name":"Team \#(n)","email":"\#(n)@example.com","type":"team"}"#
    }

    private func envelope(_ n: Int) -> String {
        #"{"owner":\#(owner(n)),"cursor":"own-\#(n)"}"#
    }

    /// A transport that serves a fixed set of owners in pages of `pageSize`, keyed off the `cursor`
    /// query parameter the client sends — mirroring Render's real cursor contract.
    private func pagingClient(total: Int, pageSize: Int) -> RenderClient {
        let makeEnvelope = envelope
        let transport = StubTransport { request, _, _ in
            let query = request.path?.components(separatedBy: "?").last ?? ""
            let cursor = query
                .components(separatedBy: "&")
                .first { $0.hasPrefix("cursor=") }
                .map { String($0.dropFirst("cursor=".count)) }
            let start = cursor.flatMap { $0.components(separatedBy: "own-").last }.flatMap(Int.init)
                .map { $0 + 1 } ?? 0
            let end = min(start + pageSize, total)
            let body = "[" + (start..<end).map(makeEnvelope).joined(separator: ",") + "]"
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(body))
        }
        return RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("rnd_test"),
            transport: transport
        )
    }

    private func paginator(for client: RenderClient, pageSize: Int)
        -> CursorPaginator<Components.Schemas.OwnerWithCursor, Components.Schemas.Owner>
    {
        CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listOwners(query: .init(cursor: cursor, limit: limit))
                .ok.body.json
        } unwrap: { envelope in
            // Both are optional in the spec; in practice a listed owner always has both. Skipping a
            // malformed envelope isn't worth the complexity here — the fixture is well-formed.
            (envelope.owner!, envelope.cursor!)
        }
    }

    @Test("listOwners pages and unwraps through CursorPaginator")
    func pagesAndUnwraps() async throws {
        let client = pagingClient(total: 5, pageSize: 2)
        let owners = try await paginator(for: client, pageSize: 2).collect()
        #expect(owners.map(\.id) == ["own-0", "own-1", "own-2", "own-3", "own-4"])
        #expect(owners.allSatisfy { $0._type == .team })
    }

    @Test("a single short page makes exactly one request")
    func singlePage() async throws {
        let client = pagingClient(total: 2, pageSize: 50)
        let first = try await paginator(for: client, pageSize: 50).firstPage()
        #expect(first.elements.map(\.id) == ["own-0", "own-1"])
        #expect(first.nextCursor == nil)
    }

    @Test("a 401 from the real stack surfaces as RenderError.unauthorized")
    func unauthorizedSurfaces() async throws {
        let transport = StubTransport(responses: [(401, [:], #"{"message":"nope"}"#)])
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("rnd_bad"),
            transport: transport
        )
        // The generated client re-wraps a middleware throw in `ClientError`; `RenderError.wrapping`
        // unwraps it back to our type — the same call every feature store makes in its catch block.
        do {
            _ = try await client.api.listOwners(query: .init()).ok.body.json
            Issue.record("expected the 401 to throw")
        } catch {
            #expect(RenderError.wrapping(error) == .unauthorized(message: nil))
        }
    }
}
