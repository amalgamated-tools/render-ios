import Foundation
import RenderAPI

/// Where a set of environment variables lives, and how to read and write it.
///
/// Two API resources hold the same thing: a service's own variables (`/services/{id}/env-vars`) and
/// an env group's (`/env-groups/{id}/env-vars`). Every decision ``EnvVarsStore`` encodes — writes one
/// key at a time, alphabetical order, key-only search, drain the whole collection, keep the list on a
/// failed refresh — is right for both, so the store takes a backend instead of a service ID and there
/// is exactly one implementation of the screen behind it.
///
/// The two differ in three ways, all of them the API's doing:
/// 1. **Loading.** A service's variables are a paginated collection. A group's arrive *inline with
///    the group* — `GET /env-groups/{id}` returns `envVars` and `secretFiles` in the body, and there
///    is no per-group list endpoint to page.
/// 2. **What a write answers with.** A service write answers with the one variable it changed. A
///    group write answers with the **whole group**, which is strictly more information than was asked
///    for and worth keeping rather than narrowing back down to one key.
/// 3. **When the change takes effect.** One service's next deploy, versus every linked service's.
struct EnvVarBackend: Sendable {
    /// What Render told us after a write.
    ///
    /// Not simplified to one case: narrowing a group's whole-set reply down to the single key we
    /// asked about would throw away a fresher view of every other variable in the group, and
    /// widening a service's single-variable reply would mean inventing the rest.
    enum WriteOutcome: Sendable {
        case entry(EnvVarEntry)
        case wholeSet([EnvVarEntry])
    }

    let scope: ConfigScope
    let load: @Sendable () async throws -> [EnvVarEntry]
    let save: @Sendable (_ key: String, _ value: String) async throws -> WriteOutcome
    let delete: @Sendable (_ key: String) async throws -> Void
}

extension EnvVarBackend {
    /// A service's own variables — the Phase 5a paths, unchanged.
    static func service(client: RenderClient, serviceID: String, pageSize: Int = 100) -> EnvVarBackend {
        EnvVarBackend(
            scope: .service,
            load: {
                try await CursorPaginator<Components.Schemas.EnvVarWithCursor, EnvVarEntry>(
                    pageSize: pageSize
                ) { cursor, limit in
                    try await client.api
                        .getEnvVarsForService(
                            path: .init(serviceId: serviceID),
                            query: .init(cursor: cursor, limit: limit)
                        )
                        .ok.body.json
                } unwrap: { envelope in
                    (EnvVarEntry(envelope.envVar), envelope.cursor)
                }
                .collect()
            },
            save: { key, value in
                let updated = try await client.api.updateEnvVar(
                    path: .init(serviceId: serviceID, envVarKey: key),
                    body: .json(.EnvVarValue(.init(value: value)))
                ).ok.body.json
                // The response, not the request: Render is the authority on what it stored.
                return .entry(EnvVarEntry(updated))
            },
            delete: { key in
                try await client.api.deleteEnvVar(
                    path: .init(serviceId: serviceID, envVarKey: key)
                ).expectSuccess()
            }
        )
    }

    /// An env group's variables, shared by every service linked to the group.
    ///
    /// - Parameter linkedServiceCount: Read off the group's `serviceLinks`, so the banner can say how
    ///   many services are waiting on a deploy rather than being vague about it.
    static func envGroup(
        client: RenderClient,
        groupID: String,
        linkedServiceCount: Int
    ) -> EnvVarBackend {
        EnvVarBackend(
            scope: .envGroup(linkedServiceCount: linkedServiceCount),
            load: {
                try await client.api
                    .retrieveEnvGroup(path: .init(envGroupId: groupID))
                    .ok.body.json
                    .value2.envVars
                    .map(EnvVarEntry.init)
            },
            save: { key, value in
                let group = try await client.api.updateEnvGroupEnvVar(
                    path: .init(envGroupId: groupID, envVarKey: key),
                    body: .json(.EnvVarValue(.init(value: value)))
                ).ok.body.json
                // A group write hands back the entire group, so take all of it.
                return .wholeSet(group.value2.envVars.map(EnvVarEntry.init))
            },
            delete: { key in
                try await client.api.deleteEnvGroupEnvVar(
                    path: .init(envGroupId: groupID, envVarKey: key)
                ).expectSuccess()
            }
        )
    }
}
