import Foundation
import RenderAPI

/// Where a set of secret files lives, and how to read and write it.
///
/// The counterpart to ``EnvVarBackend``, with the same three differences between a service's files and
/// an env group's — paged versus inline, one-file reply versus whole-group reply, one deploy versus
/// every linked service's — plus a fourth that is this resource's alone:
///
/// **The service-scoped write doesn't match its own spec.** `PUT /services/{id}/secret-files/{name}`
/// answers **200**, not the documented 201, and the body it sends back describes an *env var*
/// (`{"key","value"}`) rather than a secret file. Measured live, 2026-08-12; before it was handled, a
/// create Render had actually performed was reported to the user as a failure to reach Render. So this
/// is the one write in the app that applies what it **sent**: Render isn't the authority on what it
/// stored here, because it doesn't say.
///
/// The group-scoped write is documented to answer 200 with the whole group, and does — but it is the
/// same endpoint family that lied once, so an undocumented 2xx is accepted there too and falls back to
/// trusting the request rather than throwing on a write that succeeded.
struct SecretFileBackend: Sendable {
    enum WriteOutcome: Sendable {
        case entry(SecretFileEntry)
        case wholeSet([SecretFileEntry])
    }

    let scope: ConfigScope
    let load: @Sendable () async throws -> [SecretFileEntry]
    let save: @Sendable (_ name: String, _ content: String) async throws -> WriteOutcome
    let delete: @Sendable (_ name: String) async throws -> Void
}

extension SecretFileBackend {
    /// A service's own secret files — the Phase 5a paths, unchanged.
    static func service(client: RenderClient, serviceID: String, pageSize: Int = 100) -> SecretFileBackend {
        SecretFileBackend(
            scope: .service,
            load: {
                try await CursorPaginator<Components.Schemas.SecretFileWithCursor, SecretFileEntry>(
                    pageSize: pageSize
                ) { cursor, limit in
                    try await client.api
                        .listSecretFilesForService(
                            path: .init(serviceId: serviceID),
                            query: .init(cursor: cursor, limit: limit)
                        )
                        .ok.body.json
                } unwrap: { envelope in
                    (SecretFileEntry(envelope.secretFile), envelope.cursor)
                }
                .collect()
            },
            save: { name, content in
                // `envVarKey` is the generated name for this path parameter — the spec reuses the env
                // var parameter for the secret file's name. It's the file name that goes in it.
                let output = try await client.api.addOrUpdateSecretFile(
                    path: .init(serviceId: serviceID, envVarKey: name),
                    body: .json(.init(content: content))
                )
                switch output {
                case .created:
                    break
                case .undocumented(let statusCode, _) where (200..<300).contains(statusCode):
                    // The 200-that-should-be-201, with its env-var-shaped body. See the type's note.
                    break
                case .undocumented(let statusCode, _):
                    throw RenderError.from(statusCode: statusCode, message: nil)
                default:
                    throw RenderError.server(statusCode: 500, message: "Render rejected the write.")
                }
                // The request, not the response — see the type's note.
                return .entry(SecretFileEntry(name: name, content: content))
            },
            delete: { name in
                try await client.api.deleteSecretFile(
                    path: .init(serviceId: serviceID, envVarKey: name)
                ).expectSuccess()
            }
        )
    }

    /// An env group's secret files, shared by every service linked to the group.
    static func envGroup(
        client: RenderClient,
        groupID: String,
        linkedServiceCount: Int
    ) -> SecretFileBackend {
        SecretFileBackend(
            scope: .envGroup(linkedServiceCount: linkedServiceCount),
            load: {
                try await client.api
                    .retrieveEnvGroup(path: .init(envGroupId: groupID))
                    .ok.body.json
                    .value2.secretFiles
                    .map(SecretFileEntry.init)
            },
            save: { name, content in
                let output = try await client.api.updateEnvGroupSecretFile(
                    path: .init(envGroupId: groupID, envVarKey: name),
                    body: .json(.init(content: content))
                )
                switch output {
                case .ok(let ok):
                    return .wholeSet(try ok.body.json.value2.secretFiles.map(SecretFileEntry.init))
                case .undocumented(let statusCode, _) where (200..<300).contains(statusCode):
                    // The write landed. Report it rather than throwing, and trust what was sent —
                    // there's no body to read it out of. Same lesson as the service-scoped path.
                    return .entry(SecretFileEntry(name: name, content: content))
                case .undocumented(let statusCode, _):
                    throw RenderError.from(statusCode: statusCode, message: nil)
                default:
                    throw RenderError.server(statusCode: 500, message: "Render rejected the write.")
                }
            },
            delete: { name in
                try await client.api.deleteEnvGroupSecretFile(
                    path: .init(envGroupId: groupID, envVarKey: name)
                ).expectSuccess()
            }
        )
    }
}
