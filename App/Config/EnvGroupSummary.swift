import Foundation
import RenderAPI

/// One env group, as the list and detail screens need it.
///
/// `serviceLinks` is carried whole rather than reduced to a count, because it is the **only** place the
/// API records which services use a group: there is no `GET /services/{id}/env-groups`. Both the
/// group's own "Linked Services" list and a service's "Environment Groups" drill-down are built by
/// reading this field.
struct EnvGroupSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let createdAt: Date
    let updatedAt: Date
    /// The environment this group belongs to, when it belongs to one. Groups can be workspace-wide.
    let environmentID: String?
    let links: [EnvGroupServiceLink]

    var linkedServiceCount: Int { links.count }

    init(_ meta: Components.Schemas.EnvGroupMeta) {
        self.id = meta.id
        self.name = meta.name
        self.createdAt = meta.createdAt
        self.updatedAt = meta.updatedAt
        self.environmentID = meta.environmentId
        self.links = meta.serviceLinks.map(EnvGroupServiceLink.init)
    }

    /// A group write answers with the whole `envGroup` — meta *and* contents — so this reads the meta
    /// half back out of it.
    init(_ group: Components.Schemas.EnvGroup) {
        self.init(group.value1)
    }

    private init(
        id: String,
        name: String,
        createdAt: Date,
        updatedAt: Date,
        environmentID: String?,
        links: [EnvGroupServiceLink]
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.environmentID = environmentID
        self.links = links
    }

    /// The group without one of its links.
    ///
    /// Needed because the unlink endpoint is the one group write that answers `204` instead of with the
    /// updated group — every other one hands back a whole `envGroup` to apply.
    func removingLink(_ serviceID: String) -> EnvGroupSummary {
        EnvGroupSummary(
            id: id,
            name: name,
            createdAt: createdAt,
            updatedAt: updatedAt,
            environmentID: environmentID,
            links: links.filter { $0.id != serviceID }
        )
    }

    /// The one-line subtitle in the list: how many services this group reaches, which is the thing
    /// that makes editing it consequential.
    var linkSummary: String {
        switch linkedServiceCount {
        case 0: "No linked services"
        case 1: "1 linked service"
        default: "\(linkedServiceCount) linked services"
        }
    }
}

/// A service a group is linked to. The `type` here is the spec's *short* service type enum.
struct EnvGroupServiceLink: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let type: Components.Schemas.ServiceTypeShort

    init(_ link: Components.Schemas.EnvGroupLink) {
        self.id = link.id
        self.name = link.name
        self.type = link._type
    }
}
