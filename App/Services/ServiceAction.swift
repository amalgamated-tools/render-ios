import RenderAPI

/// The lifecycle actions the detail screen can take on a service.
///
/// Each case carries its own confirmation copy: these are the "3am, one-handed, on a phone" actions,
/// so every one is gated behind a dialog that names the service and says what will happen. The
/// wording matters as much as the call does — `restart` and `suspend` are one row apart in the menu.
enum ServiceAction: Identifiable, Hashable {
    /// What a deploy actually ships, which decides the wording. Render deploys either the latest
    /// commit on a branch or the latest image from a registry, and telling a user running an
    /// image-backed service that we'll "build the latest commit on the branch" is simply wrong.
    enum Source: Hashable {
        case commit
        case image

        var deployTitle: String {
            switch self {
            case .commit: "Deploy Latest Commit"
            case .image: "Deploy Latest Image"
            }
        }

        var deployMessage: String {
            switch self {
            case .commit: "Builds and deploys the latest commit on the service's branch."
            case .image: "Pulls and deploys the latest image from the service's registry."
            }
        }
    }

    case deploy(clearCache: Bool, source: Source)
    case rollback(deployID: String)
    case cancelDeploy(deployID: String)
    case restart
    case suspend
    case resume
    case scale(instances: Int)
    case purgeCache
    case runCronJob

    var id: String {
        switch self {
        case .deploy(let clearCache, _): "deploy-\(clearCache)"
        case .rollback(let deployID): "rollback-\(deployID)"
        case .cancelDeploy(let deployID): "cancel-\(deployID)"
        case .restart: "restart"
        case .suspend: "suspend"
        case .resume: "resume"
        case .scale(let instances): "scale-\(instances)"
        case .purgeCache: "purge-cache"
        case .runCronJob: "run-cron-job"
        }
    }

    var title: String {
        switch self {
        case .deploy(let clearCache, let source): clearCache ? "Deploy (Clear Cache)" : source.deployTitle
        case .rollback: "Roll Back to This Deploy"
        case .cancelDeploy: "Cancel Deploy"
        case .restart: "Restart"
        case .suspend: "Suspend"
        case .resume: "Resume"
        case .scale(let instances): "Scale to \(instances)"
        case .purgeCache: "Purge Cache"
        case .runCronJob: "Trigger Run"
        }
    }

    var systemImage: String {
        switch self {
        case .deploy: "arrow.up.circle"
        case .rollback: "arrow.uturn.backward"
        case .cancelDeploy: "xmark.circle"
        case .restart: "arrow.clockwise"
        case .suspend: "pause.circle"
        case .resume: "play.circle"
        case .scale: "arrow.up.arrow.down"
        case .purgeCache: "trash"
        case .runCronJob: "play.circle"
        }
    }

    /// Drives destructive styling in the menu and dialog. "Destructive" here means *user-visible
    /// impact* — a suspend takes the service offline — not irreversibility.
    var isDestructive: Bool {
        switch self {
        case .suspend, .restart, .rollback, .cancelDeploy: true
        case .deploy, .resume, .scale, .purgeCache, .runCronJob: false
        }
    }

    func confirmationTitle(serviceName: String) -> String {
        switch self {
        case .deploy(let clearCache, _):
            clearCache ? "Deploy \(serviceName) with a clean build cache?" : "Deploy \(serviceName)?"
        case .rollback: "Roll back \(serviceName)?"
        case .cancelDeploy: "Cancel the in-progress deploy?"
        case .restart: "Restart \(serviceName)?"
        case .suspend: "Suspend \(serviceName)?"
        case .resume: "Resume \(serviceName)?"
        case .scale(let instances): "Scale \(serviceName) to \(instances) instance\(instances == 1 ? "" : "s")?"
        case .purgeCache: "Purge the cache for \(serviceName)?"
        case .runCronJob: "Trigger a run of \(serviceName)?"
        }
    }

    var confirmationMessage: String {
        switch self {
        case .deploy(let clearCache, let source):
            clearCache
                ? "Builds from scratch without the build cache. Slower than a normal deploy."
                : source.deployMessage
        case .rollback:
            // Straight from the endpoint's own docs — the footgun worth spelling out on a phone.
            "Redeploys this build. Auto-deploy stays on, so a later commit can restore the changes you're rolling back."
        case .cancelDeploy:
            "Stops the deploy in progress. The previous version keeps serving traffic."
        case .restart:
            "Restarts every instance. Expect a brief interruption."
        case .suspend:
            "Takes the service offline until you resume it. It stops serving traffic immediately."
        case .resume:
            "Brings the service back online."
        case .scale:
            "Render ignores this while autoscaling is enabled for the service."
        case .purgeCache:
            "Clears cached responses. The next requests go to your service."
        case .runCronJob:
            "Starts a run now and cancels any run already in progress."
        }
    }

    /// Shown in the banner after the call succeeds. Deliberately phrased as "requested", because
    /// every one of these endpoints is asynchronous — a 202 means Render accepted the intent.
    var successMessage: String {
        switch self {
        case .deploy: "Deploy started."
        case .rollback: "Rollback started."
        case .cancelDeploy: "Deploy canceled."
        case .restart: "Restart requested."
        case .suspend: "Service suspended."
        case .resume: "Resume requested."
        case .scale(let instances): "Scaling to \(instances) instance\(instances == 1 ? "" : "s")."
        case .purgeCache: "Cache purge requested."
        case .runCronJob: "Cron run triggered."
        }
    }
}

extension Components.Schemas.ServiceType {
    /// Types Render will restart — cron jobs have no long-lived process. From the endpoint's docs.
    var supportsRestart: Bool { self != .cronJob }

    /// Types with a `numInstances` to set.
    var supportsScaling: Bool {
        switch self {
        case .webService, .privateService, .backgroundWorker: true
        case .staticSite, .cronJob: false
        }
    }

    /// `POST /services/{id}/cache/purge` is documented for web services only.
    var supportsCachePurge: Bool { self == .webService }
}
