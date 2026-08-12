import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPITestSupport
import Testing

@testable import RenderAPI

/// Fixture tests for the undiscriminated `service.serviceDetails` union — the highest-risk decode in
/// the app. Every case goes through the **real** generated client (only the transport is stubbed) so
/// the assertions cover the generator's actual first-match decoder and the `oneOf` ordering baked in
/// by `Scripts/order-oneof.py`, not a hand-rolled approximation of either.
@Suite("Service details")
struct ServiceDetailsTests {
    // MARK: - Fixtures

    /// Native (non-Docker) `envSpecificDetails`.
    private static let nativeEnv = #"{"buildCommand":"npm ci","startCommand":"npm start"}"#
    private static let dockerEnv =
        #"{"dockerCommand":"./run","dockerContext":".","dockerfilePath":"./Dockerfile"}"#

    /// A whole `service` response, with `type` and `serviceDetails` supplied per case. The rest is
    /// the service schema's required set, which the generated decoder enforces in full.
    private func serviceJSON(type: String, details: String) -> String {
        """
        {
          "id": "srv-abc",
          "name": "api",
          "ownerId": "own-1",
          "type": "\(type)",
          "createdAt": "2026-08-11T19:59:22.275356Z",
          "updatedAt": "2026-08-11T19:59:22.275356Z",
          "dashboardUrl": "https://dashboard.render.com/web/srv-abc",
          "suspended": "not_suspended",
          "suspenders": [],
          "autoDeploy": "yes",
          "notifyOnFail": "default",
          "slug": "api",
          "rootDir": "./",
          "serviceDetails": \(details)
        }
        """
    }

    /// Retrieves the fixture through the real stack and projects it, exactly as a feature store does.
    private func details(type: String, details: String) async throws -> ServiceDetails {
        let body = serviceJSON(type: type, details: details)
        let transport = StubTransport { _, _, _ in
            var response = HTTPResponse(status: .ok)
            response.headerFields[.contentType] = "application/json"
            return (response, HTTPBody(body))
        }
        let client = RenderClient(apiKeyProvider: StaticAPIKeyProvider("rnd_test"), transport: transport)
        let service = try await client.api
            .retrieveService(path: .init(serviceId: "srv-abc"))
            .ok.body.json
        return ServiceDetails(service)
    }

    // MARK: - One case per service type

    @Test("a static site decodes as a static site")
    func staticSite() async throws {
        let details = try await details(
            type: "static_site",
            details: #"{"buildCommand":"npm run build","publishPath":"dist","url":"https://x.onrender.com","buildPlan":"starter"}"#
        )
        #expect(details.type == .staticSite)
        #expect(details.matchesDeclaredType)
        #expect(details.publishPath == "dist")
        #expect(details.commands?.buildCommand == "npm run build")
        // A static site has no instance/region concept — the projection must not invent one.
        #expect(details.numInstances == nil)
        #expect(details.region == nil)
        #expect(details.plan == nil)
    }

    @Test("a web service decodes as a web service, not a static site")
    func webService() async throws {
        let details = try await details(
            type: "web_service",
            details: """
            {"env":"node","runtime":"node","envSpecificDetails":\(Self.nativeEnv),
             "plan":"standard","region":"oregon","numInstances":3,"buildPlan":"starter",
             "healthCheckPath":"/healthz","url":"https://api.onrender.com",
             "openPorts":[{"port":10000,"protocol":"TCP"}],
             "disk":{"id":"dsk-1","name":"data","sizeGB":10,"mountPath":"/data"},
             "autoscaling":{"enabled":true,"min":2,"max":8,
               "criteria":{"cpu":{"enabled":true,"percentage":70},"memory":{"enabled":false,"percentage":80}}},
             "maintenanceMode":{"enabled":false,"uri":""},
             "sshAddress":"srv-abc@ssh.oregon.render.com"}
            """
        )
        #expect(details.type == .webService)
        #expect(details.matchesDeclaredType)
        #expect(details.numInstances == 3)
        #expect(details.healthCheckPath == "/healthz")
        #expect(details.region == .oregon)
        #expect(details.plan == .standard)
        #expect(details.openPorts == [10000])
        #expect(details.disk?.mountPath == "/data")
        #expect(details.autoscaling == .init(isEnabled: true, min: 2, max: 8))
        #expect(details.isMaintenanceModeEnabled == false)
        #expect(details.sshAddress == "srv-abc@ssh.oregon.render.com")
        #expect(details.commands?.isDocker == false)
        #expect(details.publishPath == nil)
    }

    @Test("a private service is not swallowed by webServiceDetails")
    func privateService() async throws {
        // The distinguishing absence is `healthCheckPath`, which webServiceDetails requires.
        let details = try await details(
            type: "private_service",
            details: """
            {"env":"go","runtime":"go","envSpecificDetails":\(Self.dockerEnv),
             "plan":"starter","region":"frankfurt","numInstances":1,"buildPlan":"starter",
             "url":"http://internal:10000","openPorts":null}
            """
        )
        #expect(details.type == .privateService)
        #expect(details.matchesDeclaredType)
        #expect(details.healthCheckPath == nil)
        #expect(details.region == .frankfurt)
        #expect(details.commands?.isDocker == true)
        #expect(details.commands?.dockerfilePath == "./Dockerfile")
        // `openPorts: null` for a required field is a known spec-vs-reality mismatch, relaxed by
        // Scripts/relax-nullable.py; it must decode to empty rather than fail the whole response.
        #expect(details.openPorts.isEmpty)
    }

    @Test("a background worker decodes as a background worker")
    func backgroundWorker() async throws {
        let details = try await details(
            type: "background_worker",
            details: """
            {"env":"python","runtime":"python","envSpecificDetails":\(Self.nativeEnv),
             "plan":"starter","region":"ohio","numInstances":2,"buildPlan":"starter"}
            """
        )
        #expect(details.type == .backgroundWorker)
        #expect(details.matchesDeclaredType)
        #expect(details.numInstances == 2)
        // A worker has no URL and no schedule; cronJobDetails must not have claimed it.
        #expect(details.url == nil)
        #expect(details.schedule == nil)
    }

    @Test("a cron job decodes as a cron job")
    func cronJob() async throws {
        let details = try await details(
            type: "cron_job",
            details: """
            {"env":"ruby","runtime":"ruby","envSpecificDetails":\(Self.nativeEnv),
             "plan":"starter","region":"virginia","schedule":"0 * * * *","buildPlan":"starter",
             "lastSuccessfulRunAt":"2026-08-11T18:00:00.123456Z"}
            """
        )
        #expect(details.type == .cronJob)
        #expect(details.matchesDeclaredType)
        #expect(details.schedule == "0 * * * *")
        #expect(details.lastSuccessfulRunAt != nil)
        #expect(details.numInstances == nil)
    }

    // MARK: - The case the ordering patch exists for

    /// The reason `Scripts/order-oneof.py` exists. `backgroundWorkerDetails`' required set is a
    /// strict subset of a cron job payload that carries `numInstances`, and unknown keys (`schedule`)
    /// are ignored — so with the spec's original member order this decodes as a background worker and
    /// the cron schedule vanishes. Don't relax this test: it is the regression guard on the patch.
    @Test("a cron job carrying numInstances still decodes as a cron job")
    func cronJobWithInstanceCountIsNotMistakenForAWorker() async throws {
        let details = try await details(
            type: "cron_job",
            details: """
            {"env":"ruby","runtime":"ruby","envSpecificDetails":\(Self.nativeEnv),
             "plan":"starter","region":"virginia","schedule":"*/5 * * * *","buildPlan":"starter",
             "numInstances":1}
            """
        )
        #expect(details.decodedType == .cronJob)
        #expect(details.matchesDeclaredType)
        #expect(details.schedule == "*/5 * * * *")
    }

    /// The tripwire itself: when the union picks a member that contradicts `service.type`, the
    /// projection reports the mismatch instead of presenting the wrong shape as fact.
    @Test("a details/type disagreement is reported, not silently trusted")
    func mismatchIsDetected() async throws {
        // A payload whose *only* decodable member is staticSiteDetails, labelled a web service.
        let details = try await details(
            type: "web_service",
            details: #"{"buildCommand":"npm run build","publishPath":"dist","url":"https://x.onrender.com","buildPlan":"starter"}"#
        )
        #expect(details.type == .webService)
        #expect(details.decodedType == .staticSite)
        #expect(details.matchesDeclaredType == false)
    }
}
