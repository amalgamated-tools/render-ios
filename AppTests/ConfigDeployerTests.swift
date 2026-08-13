import Foundation
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

@MainActor
@Suite("ConfigDeployer")
struct ConfigDeployerTests {
    private func deployer(client: RenderClient, source: ServiceAction.Source = .commit) -> ConfigDeployer {
        ConfigDeployer(client: client, serviceID: "srv-1", serviceName: "api", source: source)
    }

    private func model(type: String, runtime: String = "node") throws -> ServiceDetailModel {
        let json = Fixtures.serviceJSON(
            type: type,
            details: Fixtures.serviceDetailsJSON(for: type, runtime: runtime)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ServiceDetailModel(
            try decoder.decode(Components.Schemas.Service.self, from: Data(json.utf8))
        )
    }

    @Test("deploying POSTs one deploy, and leaves the build cache alone")
    func postsOneDeploy() async throws {
        // The banner deploys the way the detail screen's plain Deploy does. A cache-clearing build
        // is a debugging tool, not what someone wants after editing a variable.
        let recorder = BodyRecorder()
        let deployer = deployer(client: recorder.client(answering: Fixtures.deploy(), status: 201))

        let result = try #require(await deployer.deploy())

        let request = try #require(recorder.requests.first)
        #expect(request.method == .post)
        #expect(request.path == "/services/srv-1/deploys")
        #expect(recorder.compactBodies.first == #"{"clearCache":"do_not_clear"}"#)
        #expect(result.isFailure == false)
    }

    @Test("202 — accepted with nothing new to build — is a success, not an error")
    func acceptedIsSuccess() async throws {
        // `POST /deploys` is the one operation with two documented success codes: 201 when Render
        // created a deploy, 202 when it accepted the request but had nothing to build.
        let (client, _) = RenderClient.routed { _ in (202, "") }

        let result = try #require(await deployer(client: client).deploy())

        #expect(result.isFailure == false)
    }

    @Test("success says the deploy started, never that the change is already live")
    func successDoesNotClaimLive() async throws {
        // The whole reason this button exists is that "saved" didn't mean "running". Saying
        // "deployed" the instant a 201 comes back would repeat that mistake one step later — the
        // build takes minutes.
        let (client, _) = RenderClient.routed { _ in (201, Fixtures.deploy()) }

        let result = try #require(await deployer(client: client).deploy())

        #expect(result.message.contains("Deploy started"))
        #expect(!result.message.localizedCaseInsensitiveContains("is live."))
    }

    @Test("the result of a deploy doesn't offer another one")
    func successStopsOfferingDeploy() async throws {
        let (client, _) = RenderClient.routed { _ in (201, Fixtures.deploy()) }

        let result = try #require(await deployer(client: client).deploy())

        // Otherwise the banner invites a second build of the same commit, one tap apart.
        #expect(result.offersDeploy == false)
    }

    @Test("a rejected deploy reports the failure")
    func failureReports() async throws {
        let (client, _) = RenderClient.routed { _ in (403, "{}") }

        let result = try #require(await deployer(client: client).deploy())

        #expect(result.isFailure)
        #expect(result.offersDeploy == false)
    }

    @Test("wording follows what the service actually deploys")
    func wordingFollowsSource() {
        let (client, _) = RenderClient.stubbed(jsonBodies: ["{}"])

        // Telling someone running an image-backed service that we'll build the latest commit on
        // their branch is simply wrong — the same defect Phase 2's live pass turned up in the menu.
        #expect(deployer(client: client, source: .commit).action.title == "Deploy Latest Commit")
        #expect(deployer(client: client, source: .image).action.title == "Deploy Latest Image")
    }

    @Test("a cron job gets no deployer — it runs, it doesn't deploy")
    func cronJobHasNoDeployer() throws {
        let (client, _) = RenderClient.stubbed(jsonBodies: ["{}"])

        #expect(ConfigDeployer.make(client: client, service: try model(type: "cron_job")) == nil)
        #expect(ConfigDeployer.make(client: client, service: try model(type: "web_service")) != nil)
    }

    @Test("an image-backed service is detected from the loaded service, not assumed")
    func sourceComesFromTheService() throws {
        let (client, _) = RenderClient.stubbed(jsonBodies: ["{}"])

        let git = try #require(ConfigDeployer.make(client: client, service: try model(type: "web_service")))
        let image = try #require(
            ConfigDeployer.make(client: client, service: try model(type: "web_service", runtime: "image"))
        )

        #expect(git.source == .commit)
        #expect(image.source == .image)
    }
}
