import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPITestSupport
import Testing

@testable import RenderAPI

@Suite("NullListMiddleware")
struct NullListMiddlewareTests {
    /// Runs one response through the middleware and returns the body it handed on.
    private func run(operationID: String, status: Int = 200, body: String) async throws -> String {
        let transport = StubTransport(responses: [(status, [:], body)])
        let request = HTTPRequest(method: .get, scheme: "https", authority: "api.render.com", path: "/v1/x")
        let (_, out) = try await NullListMiddleware().intercept(
            request,
            body: nil,
            baseURL: URL(string: "https://api.render.com/v1")!,
            operationID: operationID
        ) { request, body, url in
            try await transport.send(request, body: body, baseURL: url, operationID: operationID)
        }
        guard let out else { return "<no body>" }
        return String(decoding: try await Data(collecting: out, upTo: .max), as: UTF8.self)
    }

    @Test("null becomes [] for the operations that send it", arguments: ["listWorkflows", "listWorkflowVersions", "listTasks"])
    func nullBecomesEmpty(operationID: String) async throws {
        #expect(try await run(operationID: operationID, body: "null\n") == "[]")
    }

    @Test("a real list passes through byte for byte")
    func listPassesThrough() async throws {
        let body = #"[{"cursor":"c","task":{"id":"tsk-1"}}]"#
        #expect(try await run(operationID: "listTasks", body: body) == body)
    }

    @Test("other operations are left alone, even when they send null")
    func otherOperations() async throws {
        #expect(try await run(operationID: "listServices", body: "null") == "null")
    }

    @Test("an error response is left alone")
    func errorsUntouched() async throws {
        #expect(try await run(operationID: "listWorkflows", status: 500, body: "null") == "null")
    }

    @Test("through the whole client, an empty workflow list decodes as empty")
    func endToEnd() async throws {
        let (client, _) = RenderClient.routed { _ in (200, "null") }
        let workflows = try await client.api.listWorkflows(query: .init()).ok.body.json
        #expect(workflows.isEmpty)
    }
}
