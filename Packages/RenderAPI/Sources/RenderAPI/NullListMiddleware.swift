import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Turns a `null` body into `[]` for the list endpoints that send `null` when nothing matches.
///
/// `GET /workflows`, `GET /workflowversions` and `GET /tasks` answer an empty result with a 200 and
/// the body `null`, not `[]`. The spec says array, so the generated decoder rejects it, and a
/// workspace with no workflows would show an error instead of an empty list. It also bites a
/// workflow that *has* versions: the page after the last one is `null` too, and ``CursorPaginator``
/// asks for that page whenever the previous one came back exactly full. (`GET /flows`, the task and
/// flow run lists, and every other list in the API send `[]`.)
///
/// Narrow on purpose: only these operations, only a 2xx, and only a body that is exactly `null`.
/// Any other body is passed on byte for byte.
public struct NullListMiddleware: ClientMiddleware {
    /// The generated operation IDs that send `null` for an empty list, checked against the live API.
    static let operationIDs: Set<String> = ["listWorkflows", "listWorkflowVersions", "listTasks"]

    public init() {}

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        guard Self.operationIDs.contains(operationID),
              response.status.kind == .successful,
              let responseBody
        else { return (response, responseBody) }

        // A page of tasks can be large, so collect it whole rather than cap it: this has to hand the
        // body on intact when it isn't `null`.
        let data = try await Data(collecting: responseBody, upTo: .max)
        let isNull = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "null"
        return (response, HTTPBody(isNull ? Data("[]".utf8) : data))
    }
}
