import Foundation
import OpenAPIRuntime

/// The parts of an event's `details` the app reads: which deploy, build or instance it was about, and
/// why it failed.
///
/// `details` arrives as a free-form object (see `Scripts/freeform-event-details.py` for why the spec's
/// union had to go). Rather than walk that dictionary by hand, it's re-encoded and decoded into this
/// struct — every field optional, so an event type that carries none of them decodes to ``empty``
/// rather than failing. The keys mirror the API exactly, including its mixed casing (`instanceID`
/// beside `deployId`).
///
/// Shapes seen in a real workspace (2026-11):
/// - `server_failed`, `job_run_ended`, `cron_job_run_ended`: `reason` *is* the failure —
///   `{"evicted":false,"nonZeroExit":1}`.
/// - `deploy_ended`, `build_ended`: the failure is one level down — `{"reason":{"failure":{…}}}` —
///   and a successful or cancelled deploy has `"reason":{}`.
/// - `auto_deploy_disabled`: `reason` is a plain string (`"manual_deploy"`).
/// - `image_pull_failed` (`{"imageURL":…,"message":…}`) and `artifact_fetch_failed`
///   (`{"buildId":…,"message":…}`) have no `reason`. Render's explanation is the top-level
///   `message`, which the spec marks required for both. (From the spec; the workspace hasn't
///   produced either yet.)
struct EventDetails: Decodable, Hashable, Sendable {
    var deployID: String?
    /// `succeeded`, `failed`, `canceled`. The event's own record of how *that* deploy ended.
    var deployStatus: String?
    var buildID: String?
    var buildStatus: String?
    var instanceID: String?
    /// Jobs and cron runs report `succeeded`/`failed` and `successful`/`unsuccessful` here. Deploys
    /// put an integer in the same key, which is dropped rather than failing the decode.
    var runStatus: String?
    var failure: EventFailure?
    /// Set when a deploy ended because its build failed (`reason.buildFailed.id`).
    var failedBuildID: String?
    /// A string `reason`, for the few event types that carry one.
    var reasonText: String?
    /// Render's own explanation, for event types that give one instead of a `reason`.
    var message: String?
    /// Which cron run a `cron_job_run_started` or `cron_job_run_ended` event is about.
    var cronRunID: String?

    static let empty = EventDetails()

    private enum CodingKeys: String, CodingKey {
        case deployId, deployStatus, buildId, buildStatus, instanceID, status, reason, message, cronJobRunId
    }

    private enum ReasonKeys: String, CodingKey {
        case failure, evicted, buildFailed
    }

    private enum BuildFailedKeys: String, CodingKey {
        case id
    }

    init(
        deployID: String? = nil,
        deployStatus: String? = nil,
        buildID: String? = nil,
        buildStatus: String? = nil,
        instanceID: String? = nil,
        runStatus: String? = nil,
        failure: EventFailure? = nil,
        failedBuildID: String? = nil,
        reasonText: String? = nil,
        message: String? = nil,
        cronRunID: String? = nil
    ) {
        self.deployID = deployID
        self.deployStatus = deployStatus
        self.buildID = buildID
        self.buildStatus = buildStatus
        self.instanceID = instanceID
        self.runStatus = runStatus
        self.failure = failure
        self.failedBuildID = failedBuildID
        self.reasonText = reasonText
        self.message = message
        self.cronRunID = cronRunID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` on each: one field of an unexpected type must not cost the others. Losing the deploy
        // ID because `status` changed shape would be a bad trade.
        deployID = try? container.decodeIfPresent(String.self, forKey: .deployId)
        deployStatus = try? container.decodeIfPresent(String.self, forKey: .deployStatus)
        buildID = try? container.decodeIfPresent(String.self, forKey: .buildId)
        buildStatus = try? container.decodeIfPresent(String.self, forKey: .buildStatus)
        instanceID = try? container.decodeIfPresent(String.self, forKey: .instanceID)
        runStatus = try? container.decodeIfPresent(String.self, forKey: .status)
        message = try? container.decodeIfPresent(String.self, forKey: .message)
        cronRunID = try? container.decodeIfPresent(String.self, forKey: .cronJobRunId)

        if let text = try? container.decodeIfPresent(String.self, forKey: .reason) {
            reasonText = text
        } else if let reason = try? container.nestedContainer(keyedBy: ReasonKeys.self, forKey: .reason) {
            if let buildFailed = try? reason.nestedContainer(keyedBy: BuildFailedKeys.self, forKey: .buildFailed) {
                failedBuildID = (try? buildFailed.decodeIfPresent(String.self, forKey: .id)) ?? ""
            }
            if reason.contains(.failure) {
                failure = try? reason.decode(EventFailure.self, forKey: .failure)
            } else if reason.contains(.evicted) {
                // Only treated as a failure when it has the failure's one required key — an empty
                // `{}` reason (a successful deploy) must not become a failure with nothing in it.
                failure = try? container.decode(EventFailure.self, forKey: .reason)
            }
        }
    }

    /// Reads a generated payload's `details`. Never throws: an event whose details can't be read is
    /// still an event, and the timeline should show it.
    init(_ container: OpenAPIObjectContainer) {
        guard let data = try? JSONEncoder().encode(container),
              let details = try? JSONDecoder().decode(EventDetails.self, from: data)
        else {
            self = .empty
            return
        }
        self = details
    }

    /// Whether a job or cron run ended badly. `nil` when this event isn't a run.
    var runFailed: Bool? {
        switch runStatus {
        case "failed", "unsuccessful": true
        case "succeeded", "successful": false
        default: nil
        }
    }
}

/// Why something stopped: Render's `failureReason`, shared by deploys, builds, instances and runs.
struct EventFailure: Decodable, Hashable, Sendable {
    var evicted: Bool
    var evictionReason: String?
    var nonZeroExit: Int?
    var memoryLimit: String?
    var earlyExit: Bool?
    var timedOutSeconds: Int?
    var timedOutReason: String?
    var unhealthy: String?

    private enum CodingKeys: String, CodingKey {
        case evicted, evictionReason, nonZeroExit, oomKilled, earlyExit, timedOutSeconds, timedOutReason,
             unhealthy
    }

    private enum OOMKeys: String, CodingKey {
        case memoryLimit
    }

    init(
        evicted: Bool = false,
        evictionReason: String? = nil,
        nonZeroExit: Int? = nil,
        memoryLimit: String? = nil,
        earlyExit: Bool? = nil,
        timedOutSeconds: Int? = nil,
        timedOutReason: String? = nil,
        unhealthy: String? = nil
    ) {
        self.evicted = evicted
        self.evictionReason = evictionReason
        self.nonZeroExit = nonZeroExit
        self.memoryLimit = memoryLimit
        self.earlyExit = earlyExit
        self.timedOutSeconds = timedOutSeconds
        self.timedOutReason = timedOutReason
        self.unhealthy = unhealthy
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        evicted = (try? container.decodeIfPresent(Bool.self, forKey: .evicted)) ?? false
        evictionReason = try? container.decodeIfPresent(String.self, forKey: .evictionReason)
        nonZeroExit = try? container.decodeIfPresent(Int.self, forKey: .nonZeroExit)
        earlyExit = try? container.decodeIfPresent(Bool.self, forKey: .earlyExit)
        timedOutSeconds = try? container.decodeIfPresent(Int.self, forKey: .timedOutSeconds)
        timedOutReason = try? container.decodeIfPresent(String.self, forKey: .timedOutReason)
        unhealthy = try? container.decodeIfPresent(String.self, forKey: .unhealthy)
        if let oom = try? container.nestedContainer(keyedBy: OOMKeys.self, forKey: .oomKilled) {
            // An OOM kill with no limit is still an OOM kill; an empty string marks it.
            memoryLimit = (try? oom.decodeIfPresent(String.self, forKey: .memoryLimit)) ?? ""
        }
    }

    /// One line for a notification body or a timeline row, most specific cause first.
    ///
    /// Out-of-memory wins over the exit code because an OOM kill *also* exits non-zero, and "exited
    /// with status 137" sends someone hunting through their code for a bug that is a plan size.
    var summary: String? {
        if let memoryLimit {
            return memoryLimit.isEmpty ? "Out of memory" : "Out of memory (\(memoryLimit) limit)"
        }
        if evicted {
            return evictionReason.map { "Evicted: \($0)" } ?? "Evicted"
        }
        if let timedOutSeconds {
            let base = "Timed out after \(Duration.seconds(timedOutSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))"
            return timedOutReason.map { "\(base): \($0)" } ?? base
        }
        if let timedOutReason {
            return "Timed out: \(timedOutReason)"
        }
        if let unhealthy, !unhealthy.isEmpty {
            return "Health check failed: \(unhealthy)"
        }
        if let nonZeroExit {
            return "Exited with status \(nonZeroExit)"
        }
        if earlyExit == true {
            return "Exited unexpectedly"
        }
        return nil
    }
}
