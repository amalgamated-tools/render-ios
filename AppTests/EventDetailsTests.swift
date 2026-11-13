import Foundation
import OpenAPIRuntime
import Testing

@testable import RenderiOS

/// Every `details` payload here is copied from a real workspace's events (IDs shortened), so the
/// parser is pinned to what Render actually sends rather than to the spec's description of it.
@Suite("EventDetails")
struct EventDetailsTests {
    /// Through `OpenAPIObjectContainer`, as the app reads it — not straight from JSON, so the bridge
    /// between the generated type and ``EventDetails`` is under test too.
    private func parse(_ json: String) throws -> EventDetails {
        let container = try JSONDecoder().decode(OpenAPIObjectContainer.self, from: Data(json.utf8))
        return EventDetails(container)
    }

    @Test("an instance failure carries the reason directly")
    func serverFailedExit() throws {
        let details = try parse(#"{"instanceID":"srv-1-stzkr","reason":{"evicted":false,"nonZeroExit":1}}"#)

        #expect(details.instanceID == "srv-1-stzkr")
        #expect(details.failure?.nonZeroExit == 1)
        #expect(details.failure?.summary == "Exited with status 1")
    }

    @Test("a failed deploy nests the reason under failure")
    func deployEndedOOM() throws {
        let details = try parse(#"""
        {"deployId":"dep-1","deployStatus":"failed",
         "reason":{"failure":{"evicted":false,"oomKilled":{"memoryLimit":"512Mi"}}},"status":4}
        """#)

        #expect(details.deployID == "dep-1")
        #expect(details.deployStatus == "failed")
        #expect(details.failure?.memoryLimit == "512Mi")
        #expect(details.failure?.summary == "Out of memory (512Mi limit)")
        // A deploy's `status` is an integer; it's dropped without costing the other fields.
        #expect(details.runStatus == nil)
    }

    @Test("an eviction says why")
    func evicted() throws {
        let details = try parse(#"""
        {"instanceID":"srv-1-dm26t","reason":{"evicted":true,
         "evictionReason":"Size of temporary storage volume /tmp exceeded the limit of 2GB"}}
        """#)

        #expect(details.failure?.summary == "Evicted: Size of temporary storage volume /tmp exceeded the limit of 2GB")
    }

    @Test("a successful deploy's empty reason is not a failure")
    func deploySucceeded() throws {
        let details = try parse(#"{"deployId":"dep-1","deployStatus":"succeeded","reason":{},"status":2}"#)

        #expect(details.deployStatus == "succeeded")
        #expect(details.failure == nil)
    }

    @Test("a deploy that failed with no recorded cause still says it failed")
    func deployFailedNoCause() throws {
        let details = try parse(#"{"deployId":"dep-1","deployStatus":"failed","reason":{},"status":4}"#)
        let event = ServiceEvent(id: "evt-1", timestamp: .now, type: .deployEnded, details: details)

        #expect(details.failure == nil)
        #expect(event.reasonSummary == "Failed")
    }

    @Test("job and cron runs read their string status")
    func runStatus() throws {
        let failedJob = try parse(#"{"jobId":"job-1","reason":{"evicted":false,"nonZeroExit":127},"status":"failed"}"#)
        let failedCron = try parse(#"{"cronJobRunId":"crn-1","status":"unsuccessful"}"#)
        let okCron = try parse(#"{"cronJobRunId":"crn-1","status":"successful"}"#)

        #expect(failedJob.runFailed == true)
        #expect(failedJob.failure?.summary == "Exited with status 127")
        #expect(failedCron.runFailed == true)
        #expect(ServiceEvent(id: "e", timestamp: .now, type: .cronJobRunEnded, details: failedCron).reasonSummary == "Failed")
        #expect(okCron.runFailed == false)
        #expect(ServiceEvent(id: "e", timestamp: .now, type: .cronJobRunEnded, details: okCron).reasonSummary == nil)
    }

    @Test("a string reason is kept as text, not a failure")
    func stringReason() throws {
        let details = try parse(#"{"reason":"manual_deploy"}"#)

        #expect(details.reasonText == "manual_deploy")
        #expect(details.failure == nil)
    }

    @Test("a deploy whose build failed records the build")
    func buildFailed() throws {
        let details = try parse(#"{"deployId":"dep-1","deployStatus":"failed","reason":{"buildFailed":{"id":"bld-1"}}}"#)

        #expect(details.failedBuildID == "bld-1")
    }

    // The two fetch failures below are shaped from the spec's required fields: no real workspace
    // event of either type has been seen yet.

    @Test("an image pull failure explains itself with its message")
    func imagePullFailed() throws {
        let details = try parse(#"""
        {"imageURL":"docker.io/acme/api:latest","message":"pull access denied: repository does not exist"}
        """#)
        let event = ServiceEvent(id: "e", timestamp: .now, type: .imagePullFailed, details: details)

        #expect(details.failure == nil)
        #expect(event.cause == "pull access denied: repository does not exist")
        #expect(event.reasonSummary == "pull access denied: repository does not exist")
    }

    @Test("an artifact fetch failure explains itself with its message")
    func artifactFetchFailed() throws {
        let details = try parse(#"{"buildId":"bld-1","message":"artifact not found"}"#)
        let event = ServiceEvent(id: "e", timestamp: .now, type: .artifactFetchFailed, details: details)

        #expect(details.buildID == "bld-1")
        #expect(event.cause == "artifact not found")
    }

    @Test("a structured failure outranks a message, and an empty message is no cause")
    func causePrecedence() {
        let both = EventDetails(failure: EventFailure(nonZeroExit: 1), message: "something else")
        let blank = EventDetails(message: "")

        #expect(ServiceEvent(id: "e", timestamp: .now, type: .serverFailed, details: both).cause == "Exited with status 1")
        #expect(ServiceEvent(id: "e", timestamp: .now, type: .imagePullFailed, details: blank).cause == nil)
    }

    @Test("out of memory outranks the exit status it also causes")
    func oomOutranksExit() {
        let failure = EventFailure(nonZeroExit: 137, memoryLimit: "4Gi")

        #expect(failure.summary == "Out of memory (4Gi limit)")
    }

    @Test("timeouts and health checks have their own wording")
    func timeoutsAndHealth() {
        #expect(EventFailure(timedOutSeconds: 900).summary == "Timed out after 15m")
        #expect(EventFailure(unhealthy: "GET /healthz returned 503").summary == "Health check failed: GET /healthz returned 503")
        #expect(EventFailure(earlyExit: true).summary == "Exited unexpectedly")
        #expect(EventFailure().summary == nil)
    }

    @Test("an event type with none of these fields reads as empty")
    func unrelatedShape() throws {
        #expect(try parse(#"{"diskId":"dsk-1","fromSizeGB":1,"toSizeGB":100}"#) == .empty)
        #expect(try parse("{}") == .empty)
    }
}
