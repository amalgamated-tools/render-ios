import Foundation
import HTTPTypes
import OpenAPIRuntime
import RenderAPI
import RenderAPITestSupport
import Testing

@testable import RenderiOS

/// Editing and removing a service's autoscaling settings: the limits the sheet enforces before
/// saving, and the requests the detail store sends.
@MainActor
@Suite("Autoscaling")
struct AutoscalingTests {
    // MARK: - Settings rules

    @Test("valid settings have no validation message")
    func validSettings() {
        let settings = AutoscalingSettings(isEnabled: true, min: 1, max: 3, cpuPercent: 70, memoryPercent: nil)
        #expect(settings.validationMessage == nil)
    }

    @Test("the rules match what the live API rejects", arguments: [
        (AutoscalingSettings(isEnabled: true, min: 0, max: 3, cpuPercent: 70, memoryPercent: nil), "between 1 and 100"),
        (AutoscalingSettings(isEnabled: true, min: 1, max: 101, cpuPercent: 70, memoryPercent: nil), "between 1 and 100"),
        (AutoscalingSettings(isEnabled: true, min: 4, max: 3, cpuPercent: 70, memoryPercent: nil), "lower than minimum"),
        (AutoscalingSettings(isEnabled: true, min: 1, max: 3, cpuPercent: 95, memoryPercent: nil), "1% and 90%"),
        (AutoscalingSettings(isEnabled: true, min: 1, max: 3, cpuPercent: nil, memoryPercent: 0), "1% and 90%"),
        (AutoscalingSettings(isEnabled: true, min: 1, max: 3, cpuPercent: nil, memoryPercent: nil), "CPU or memory target"),
    ])
    func invalidSettings(settings: AutoscalingSettings, reason: String) {
        #expect(settings.validationMessage?.contains(reason) == true)
    }

    @Test("turning autoscaling off doesn't need a target, as the live API allows")
    func disabledNeedsNoTarget() {
        let settings = AutoscalingSettings(isEnabled: false, min: 1, max: 3, cpuPercent: nil, memoryPercent: nil)
        #expect(settings.validationMessage == nil)
    }

    @Test("an equal minimum and maximum is allowed")
    func equalMinAndMax() {
        let settings = AutoscalingSettings(isEnabled: true, min: 2, max: 2, cpuPercent: 70, memoryPercent: nil)
        #expect(settings.validationMessage == nil)
        #expect(settings.summary == "Holds 2 instances, targeting CPU 70%.")
    }

    @Test("saved settings load into the editor, keeping a default percentage for a target that's off")
    func loadsSavedSettings() {
        let saved = ServiceDetails.Autoscaling(isEnabled: true, min: 2, max: 8, cpuTarget: nil, memoryTarget: 60)
        let settings = AutoscalingSettings(saved, currentInstances: 3)
        #expect(settings == AutoscalingSettings(isEnabled: true, min: 2, max: 8, cpuPercent: nil, memoryPercent: 60))
        #expect(settings.cpuPercent == 70)
        #expect(settings.summary == "Scales between 2 and 8 instances, targeting memory 60%.")
    }

    @Test("a service with no settings starts from its current count and a CPU target")
    func defaultsForNewSettings() {
        let settings = AutoscalingSettings(nil, currentInstances: 3)
        #expect(settings == AutoscalingSettings(isEnabled: true, min: 3, max: 6, cpuPercent: 70, memoryPercent: nil))
        #expect(settings.validationMessage == nil)
        #expect(AutoscalingSettings(nil, currentInstances: 80).max == 100)
    }

    // MARK: - Store

    /// Records the autoscaling request bodies so a test can check what was sent.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [String] = []

        var bodies: [String] {
            get { lock.withLock { _bodies } }
            set { lock.withLock { _bodies = newValue } }
        }
    }

    private nonisolated static let autoscaledService = Fixtures.serviceJSON(type: "web_service", details: """
        {"env":"node","runtime":"node","envSpecificDetails":{"buildCommand":"npm ci","startCommand":"npm start"},\
        "plan":"standard","region":"oregon","buildPlan":"starter","numInstances":2,"healthCheckPath":"",\
        "url":"https://x.onrender.com","autoscaling":{"enabled":true,"min":2,"max":5,\
        "criteria":{"cpu":{"enabled":false,"percentage":70},"memory":{"enabled":true,"percentage":75}}}}
        """)

    private func store(recorder: Recorder) -> (ServiceDetailStore, StubTransport) {
        let transport = StubTransport { request, body, _ in
            let path = request.path ?? ""
            let (status, responseBody): (Int, String?)
            if path.contains("/autoscaling") {
                if let body {
                    let data = try await Data(collecting: body, upTo: 1 << 16)
                    recorder.bodies.append(String(decoding: data, as: UTF8.self))
                }
                (status, responseBody) = request.method == .delete
                    ? (204, nil)
                    : (200, #"{"enabled":true,"min":1,"max":4,"criteria":{"cpu":{"enabled":true,"percentage":60},"memory":{"enabled":false,"percentage":80}}}"#)
            } else if path.contains("/deploys") {
                (status, responseBody) = (200, Fixtures.deploysPage([(id: "dep-1", status: "live")]))
            } else {
                (status, responseBody) = (200, Self.autoscaledService)
            }
            var response = HTTPResponse(status: .init(code: status))
            response.headerFields = [.contentType: "application/json"]
            return (response, responseBody.map { HTTPBody($0) })
        }
        let client = RenderClient(
            apiKeyProvider: StaticAPIKeyProvider("test-key"),
            retryPolicy: .none,
            transport: transport
        )
        return (ServiceDetailStore(client: client, serviceID: "srv-1", pollInterval: .seconds(3600)), transport)
    }

    @Test("the service's targets decode, with a disabled target as nil")
    func decodesTargets() async {
        let (store, _) = store(recorder: Recorder())
        await store.load()
        #expect(store.service?.details.autoscaling == .init(isEnabled: true, min: 2, max: 5, cpuTarget: nil, memoryTarget: 75))
    }

    @Test("saving sends every field to PUT /autoscaling, then reloads")
    func savesSettings() async throws {
        let recorder = Recorder()
        let (store, transport) = store(recorder: recorder)
        await store.load()
        let loads = transport.requests.count

        let settings = AutoscalingSettings(isEnabled: true, min: 1, max: 4, cpuPercent: 60, memoryPercent: nil)
        await store.perform(.setAutoscaling(settings))

        let put = try #require(transport.requests.first { $0.method == .put })
        #expect(put.path?.hasSuffix("/services/srv-1/autoscaling") == true)
        let body = try #require(recorder.bodies.first)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? NSDictionary)
        #expect(json == [
            "enabled": true, "min": 1, "max": 4,
            "criteria": ["cpu": ["enabled": true, "percentage": 60], "memory": ["enabled": false, "percentage": 70]],
        ] as NSDictionary)
        #expect(store.actionResult?.message == "Autoscaling updated.")
        #expect(store.actionResult?.isFailure == false)
        #expect(transport.requests.count > loads + 1, "reloads after saving")
    }

    @Test("removing sends DELETE /autoscaling")
    func removesSettings() async throws {
        let (store, transport) = store(recorder: Recorder())
        await store.load()

        await store.perform(.removeAutoscaling)

        let delete = try #require(transport.requests.first { $0.method == .delete })
        #expect(delete.path?.hasSuffix("/services/srv-1/autoscaling") == true)
        #expect(store.actionResult?.message == "Autoscaling removed.")
        #expect(store.actionResult?.isFailure == false)
    }
}
