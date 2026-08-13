import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPITestSupport
import Testing

@testable import RenderAPI

/// Fixture tests for the Postgres and Key Value list decodes, pinning the three places Render's spec
/// disagrees with what Render actually sends.
///
/// Written the same way as ``ServiceDetailsTests`` and for the same reason: everything goes through
/// the **real** generated client, so what's under test is the decoder the app runs, including the
/// spec patches `Scripts/relax-nullable.py` and `Scripts/widen-enums.py` apply at generation time. A
/// hand-rolled decoder would pass whatever the spec says and tell us nothing.
///
/// Each payload below is a real response, trimmed. All three mismatches shipped as the same symptom —
/// "Render returned data this version of the app doesn't understand" over an entire tab, because the
/// generated client decodes the whole response before any domain mapping runs, so one legacy value in
/// one row loses every row.
@Suite("Datastore decoding")
struct DatastoreDecodeTests {
    private func listPostgres(_ body: String) async throws -> [Components.Schemas.Postgres] {
        let transport = StubTransport { _, _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(body))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("rnd_test"), transport: transport)
        return try await client.api.listPostgres(query: .init(ownerId: ["tea-1"]))
            .ok.body.json.map(\.postgres)
    }

    private func listKeyValue(_ body: String) async throws -> [Components.Schemas.KeyValue] {
        let transport = StubTransport { _, _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(body))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("rnd_test"), transport: transport)
        return try await client.api.listKeyValue(query: .init(ownerId: ["tea-1"]))
            .ok.body.json.map(\.keyValue)
    }

    private static let owner = """
    {"id":"tea-1","name":"Workspace","email":"dev@example.com","type":"team"}
    """

    private static func postgres(plan: String, version: String, ipAllowList: String) -> String {
        """
        [{"cursor":"c1","postgres":{
          "id":"dpg-1","name":"rails","createdAt":"2018-07-25T04:58:16.43705Z",
          "updatedAt":"2023-03-23T21:43:28.577814Z","databaseName":"rails","databaseUser":"rails",
          "highAvailabilityEnabled":false,"diskAutoscalingEnabled":false,"connectionPool":"none",
          "dashboardUrl":"https://dashboard.render.com/d/dpg-1","owner":\(owner),
          "plan":"\(plan)","region":"oregon","role":"primary","status":"suspended",
          "suspended":"suspended","suspenders":["user"],"readReplicas":[],
          "version":"\(version)","ipAllowList":\(ipAllowList)}}]
        """
    }

    /// Postgres 10 is past end of life and can't be created any more, which is presumably why the
    /// spec dropped it from `postgresVersion` — but instances from 2018 are still running, and this
    /// app is exactly the tool you'd want for looking at one.
    @Test("a database on a Postgres version the spec no longer lists still decodes")
    func retiredPostgresVersion() async throws {
        let databases = try await listPostgres(Self.postgres(plan: "starter", version: "10", ipAllowList: "[]"))
        #expect(databases.first?.version == ._10)
    }

    /// Same shape of problem on the other axis: a plan that predates the current names.
    @Test("a database on a legacy plan still decodes")
    func legacyPlan() async throws {
        let databases = try await listPostgres(Self.postgres(plan: "starter_legacy", version: "17", ipAllowList: "[]"))
        #expect(databases.first?.plan == .starterLegacy)
    }

    /// The spec has `ipAllowList` required and non-nullable. Render sends `null` for a datastore with
    /// no rules, which is most of them.
    @Test("a null ipAllowList decodes as no rules rather than failing the whole list")
    func nullPostgresAllowList() async throws {
        let databases = try await listPostgres(Self.postgres(plan: "starter", version: "17", ipAllowList: "null"))
        #expect(databases.first?.ipAllowList == nil)
    }

    @Test("a Key Value instance with a null ipAllowList decodes too")
    func nullKeyValueAllowList() async throws {
        let instances = try await listKeyValue("""
        [{"cursor":"c1","keyValue":{
          "id":"red-1","name":"cache","createdAt":"2023-09-05T22:30:51.287661Z",
          "updatedAt":"2024-05-16T19:40:42.484813Z","status":"available","region":"oregon",
          "plan":"starter","owner":\(Self.owner),
          "options":{"maxmemoryPolicy":"allkeys_lru","persistenceMode":"journal_snapshot"},
          "version":"6.2.20","dashboardUrl":"https://dashboard.render.com/r/red-1",
          "ipAllowList":null}}]
        """)
        #expect(instances.first?.ipAllowList == nil)
        #expect(instances.first?.name == "cache")
    }
}
