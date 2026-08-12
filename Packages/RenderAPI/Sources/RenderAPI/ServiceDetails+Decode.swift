import Foundation

/// A flat, type-safe read of `service.serviceDetails`, keyed off the authoritative `service.type`.
///
/// ## Why this exists
///
/// `service.serviceDetails` is a `oneOf` with **no discriminator**, so the generated
/// `Components.Schemas.Service.ServiceDetailsPayload` decodes by trying each member in declaration
/// order and keeping the first that succeeds. Two independent problems follow, and this type is the
/// second half of the fix:
///
/// 1. **Ordering** decides correctness. Fixed upstream of the generator by `Scripts/order-oneof.py`,
///    which moves `cronJobDetails` ahead of `backgroundWorkerDetails` — otherwise a cron job
///    response carrying `numInstances` satisfies every background-worker requirement and every cron
///    job silently decodes as a worker.
/// 2. **Which member decoded is not evidence of what the service is.** `service.type` is, and it is
///    a sibling field the union decoder never looks at. So nothing here is inferred from the case:
///    ``type`` always comes from `service.type`, and ``decodedType`` records which member the
///    generator picked purely so a disagreement can be *detected* rather than displayed as fact.
///
/// Re-decoding the payload into the correct member is not an option: by the time app code sees a
/// `Service`, the raw JSON is gone and re-encoding the misclassified case would have already dropped
/// the fields that case's struct lacks. The ordering patch is therefore the real fix, and
/// ``matchesDeclaredType`` is the tripwire that says the ordering assumption stopped holding.
///
/// Fields absent for a given service type are `nil` — a static site has no `region`, a cron job has
/// no `numInstances`. Views read what they need and skip what's missing.
public struct ServiceDetails: Sendable, Hashable {
    /// Disk attached to the service, flattened out of the per-type nested payload.
    public struct Disk: Sendable, Hashable {
        public let id: String
        public let name: String
        public let sizeGB: Int
        public let mountPath: String
    }

    /// Autoscaling configuration, flattened out of the per-type nested payload.
    public struct Autoscaling: Sendable, Hashable {
        public let isEnabled: Bool
        public let min: Int
        public let max: Int
    }

    /// Build/start commands, flattened out of the nested `envSpecificDetails` union.
    public struct Commands: Sendable, Hashable {
        public let buildCommand: String?
        public let startCommand: String?
        public let dockerCommand: String?
        public let dockerfilePath: String?
        public let dockerContext: String?
        public let preDeployCommand: String?

        /// True for a Docker-built service — i.e. the union decoded as `dockerDetails`.
        public var isDocker: Bool { dockerfilePath != nil }
    }

    /// What the service *is*, from `service.type`. Always trust this over ``decodedType``.
    public let type: Components.Schemas.ServiceType
    /// Which `oneOf` member the generated decoder chose. Diagnostic only — see ``matchesDeclaredType``.
    public let decodedType: Components.Schemas.ServiceType

    public let plan: Components.Schemas.Plan?
    public let buildPlan: Components.Schemas.BuildPlan?
    public let region: Components.Schemas.Region?
    public let runtime: Components.Schemas.ServiceRuntime?
    public let numInstances: Int?
    public let url: String?
    public let healthCheckPath: String?
    public let publishPath: String?
    /// Cron expression. Cron jobs only.
    public let schedule: String?
    /// Cron jobs only.
    public let lastSuccessfulRunAt: Date?
    public let sshAddress: String?
    public let openPorts: [Int]
    public let disk: Disk?
    public let autoscaling: Autoscaling?
    public let isMaintenanceModeEnabled: Bool
    public let commands: Commands?

    /// False when the union decoded as a different service type than `service.type` declares — which
    /// means the spec's `oneOf` ordering no longer matches what the API returns. Any field above may
    /// then be `nil` or wrong even though the service has a value for it, so UI should treat details
    /// as untrustworthy (not merely absent) when this is false.
    public var matchesDeclaredType: Bool { type == decodedType }

    public init(_ service: Components.Schemas.Service) {
        self.type = service._type

        switch service.serviceDetails {
        case .StaticSiteDetails(let details):
            self.decodedType = .staticSite
            self.plan = nil
            self.buildPlan = details.buildPlan
            self.region = nil
            self.runtime = nil
            self.numInstances = nil
            self.url = details.url
            self.healthCheckPath = nil
            self.publishPath = details.publishPath
            self.schedule = nil
            self.lastSuccessfulRunAt = nil
            self.sshAddress = nil
            self.openPorts = []
            self.disk = nil
            self.autoscaling = nil
            self.isMaintenanceModeEnabled = false
            // A static site has no `envSpecificDetails`; its build command sits at the top level.
            self.commands = Commands(
                buildCommand: details.buildCommand,
                startCommand: nil,
                dockerCommand: nil,
                dockerfilePath: nil,
                dockerContext: nil,
                preDeployCommand: nil
            )

        case .WebServiceDetails(let details):
            self.decodedType = .webService
            self.plan = details.plan
            self.buildPlan = details.buildPlan
            self.region = details.region
            self.runtime = details.runtime
            self.numInstances = details.numInstances
            self.url = details.url
            self.healthCheckPath = details.healthCheckPath
            self.publishPath = nil
            self.schedule = nil
            self.lastSuccessfulRunAt = nil
            self.sshAddress = details.sshAddress
            self.openPorts = (details.openPorts ?? []).map(\.port)
            self.disk = details.disk.map {
                Disk(id: $0.id, name: $0.name, sizeGB: $0.sizeGB, mountPath: $0.mountPath)
            }
            self.autoscaling = details.autoscaling.map {
                Autoscaling(isEnabled: $0.enabled, min: $0.min, max: $0.max)
            }
            self.isMaintenanceModeEnabled = details.maintenanceMode?.enabled ?? false
            self.commands = Commands(details.envSpecificDetails)

        case .PrivateServiceDetails(let details):
            self.decodedType = .privateService
            self.plan = details.plan
            self.buildPlan = details.buildPlan
            self.region = details.region
            self.runtime = details.runtime
            self.numInstances = details.numInstances
            self.url = details.url
            self.healthCheckPath = nil
            self.publishPath = nil
            self.schedule = nil
            self.lastSuccessfulRunAt = nil
            self.sshAddress = details.sshAddress
            self.openPorts = (details.openPorts ?? []).map(\.port)
            self.disk = details.disk.map {
                Disk(id: $0.id, name: $0.name, sizeGB: $0.sizeGB, mountPath: $0.mountPath)
            }
            self.autoscaling = details.autoscaling.map {
                Autoscaling(isEnabled: $0.enabled, min: $0.min, max: $0.max)
            }
            self.isMaintenanceModeEnabled = false
            self.commands = Commands(details.envSpecificDetails)

        case .BackgroundWorkerDetails(let details):
            self.decodedType = .backgroundWorker
            self.plan = details.plan
            self.buildPlan = details.buildPlan
            self.region = details.region
            self.runtime = details.runtime
            self.numInstances = details.numInstances
            self.url = nil
            self.healthCheckPath = nil
            self.publishPath = nil
            self.schedule = nil
            self.lastSuccessfulRunAt = nil
            self.sshAddress = details.sshAddress
            self.openPorts = []
            self.disk = details.disk.map {
                Disk(id: $0.id, name: $0.name, sizeGB: $0.sizeGB, mountPath: $0.mountPath)
            }
            self.autoscaling = details.autoscaling.map {
                Autoscaling(isEnabled: $0.enabled, min: $0.min, max: $0.max)
            }
            self.isMaintenanceModeEnabled = false
            self.commands = Commands(details.envSpecificDetails)

        case .CronJobDetails(let details):
            self.decodedType = .cronJob
            self.plan = details.plan
            self.buildPlan = details.buildPlan
            self.region = details.region
            self.runtime = details.runtime
            self.numInstances = nil
            self.url = nil
            self.healthCheckPath = nil
            self.publishPath = nil
            self.schedule = details.schedule
            self.lastSuccessfulRunAt = details.lastSuccessfulRunAt
            self.sshAddress = nil
            self.openPorts = []
            self.disk = nil
            self.autoscaling = nil
            self.isMaintenanceModeEnabled = false
            self.commands = Commands(details.envSpecificDetails)
        }
    }
}

extension ServiceDetails.Commands {
    /// Flattens the nested `envSpecificDetails` union. Undiscriminated like its parent, but
    /// unambiguous in both directions: `dockerDetails` requires `dockerfilePath`, which a native
    /// build never has, and `nativeEnvironmentDetails` requires `startCommand`, which Docker's
    /// schema has no property for.
    init(_ envSpecificDetails: Components.Schemas.EnvSpecificDetails) {
        switch envSpecificDetails {
        case .DockerDetails(let docker):
            self.init(
                buildCommand: nil,
                startCommand: nil,
                dockerCommand: docker.dockerCommand,
                dockerfilePath: docker.dockerfilePath,
                dockerContext: docker.dockerContext,
                preDeployCommand: docker.preDeployCommand
            )
        case .NativeEnvironmentDetails(let native):
            self.init(
                buildCommand: native.buildCommand,
                startCommand: native.startCommand,
                dockerCommand: nil,
                dockerfilePath: nil,
                dockerContext: nil,
                preDeployCommand: native.preDeployCommand
            )
        }
    }
}
