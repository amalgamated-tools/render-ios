import Foundation
import Observation
import RenderAPI

/// One secret file: a name (which is also its path in the service's filesystem) and its contents.
struct SecretFileEntry: Identifiable, Hashable, Sendable {
    /// Render addresses secret files by name, so the name is the identity.
    var id: String { name }
    let name: String
    let content: String

    init(name: String, content: String) {
        self.name = name
        self.content = content
    }

    init(_ file: Components.Schemas.SecretFile) {
        self.init(name: file.name, content: file.content)
    }

    /// A one-line summary for the list, which never shows contents: "12 lines · 480 bytes".
    var summary: String {
        let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count
        let bytes = content.utf8.count
        return "\(lines) line\(lines == 1 ? "" : "s") · \(bytes) byte\(bytes == 1 ? "" : "s")"
    }
}

/// Reads and writes a service's secret files.
///
/// The same shape as ``EnvVarsStore`` and for the same reasons: writes address one file at a time
/// (`PUT /services/{id}/secret-files/{name}`) rather than replacing the whole set, and — as with env
/// vars — an API write changes the configuration without starting a deploy, so the running service
/// keeps the old file until the next one.
///
/// One difference worth naming: a secret file's *contents* are the secret, and they're often
/// several kilobytes of PEM or JSON. They are never rendered in the list — only a size summary —
/// and the editor reveals them behind an explicit tap.
///
/// A second, uglier difference: the write endpoint doesn't match its own spec. It answers 200 rather
/// than the documented 201, and the body it sends back describes an env var, not a secret file — so
/// unlike every other write in the app, this one applies what it *sent*. See ``save(name:content:)``.
@MainActor
@Observable
final class SecretFilesStore {
    private(set) var files: [SecretFileEntry] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var writeInFlight: String?
    private(set) var actionResult: ConfigActionResult?

    /// Starts a deploy from the success banner. `nil` when the service can't be deployed.
    let deployer: ConfigDeployer?

    private let client: RenderClient
    private let serviceID: String
    private let pageSize: Int

    init(
        client: RenderClient,
        serviceID: String,
        deployer: ConfigDeployer? = nil,
        pageSize: Int = 100
    ) {
        self.client = client
        self.serviceID = serviceID
        self.deployer = deployer
        self.pageSize = pageSize
    }

    var sortedFiles: [SecretFileEntry] {
        files.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Reading

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            files = try await makePaginator().collect()
            errorMessage = nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    // MARK: - Writing

    @discardableResult
    func save(name: String, content: String) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, writeInFlight == nil else { return false }

        writeInFlight = name
        actionResult = nil
        defer { writeInFlight = nil }

        do {
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
                // What Render actually does, measured 2026-08-12: this PUT answers **200**, not the
                // documented 201 — and its body is env-var shaped (`{"key","value"}`), not a secret
                // file. So the spec's success case never matches a real reply, and the reply can't
                // be applied even when it arrives. Accepting any 2xx and trusting the request is the
                // only honest reading. Before this, a create that Render had *performed* was
                // reported to the user as a failure to reach Render.
                break
            case .undocumented(let statusCode, _):
                throw RenderError.from(statusCode: statusCode, message: nil)
            default:
                throw RenderError.server(statusCode: 500, message: "Render rejected the write.")
            }
            // The request, not the response — see above. This is the one write in the app where
            // Render isn't the authority on what it stored, because it doesn't say.
            apply(SecretFileEntry(name: name, content: content))
            actionResult = .success(
                "\(name) saved. It takes effect on the next deploy.",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    @discardableResult
    func delete(name: String) async -> Bool {
        guard writeInFlight == nil else { return false }
        writeInFlight = name
        actionResult = nil
        defer { writeInFlight = nil }

        do {
            _ = try await client.api.deleteSecretFile(
                path: .init(serviceId: serviceID, envVarKey: name)
            ).noContent
            files.removeAll { $0.name == name }
            actionResult = .success(
                "\(name) deleted. It takes effect on the next deploy.",
                offersDeploy: deployer != nil
            )
            return true
        } catch {
            actionResult = .failure(error)
            return false
        }
    }

    /// Deploys the service, so the change the banner is reporting becomes the one that's running.
    func deployNow() async {
        guard writeInFlight == nil, let deployer else { return }
        if let result = await deployer.deploy() {
            actionResult = result
        }
    }

    func dismissActionResult() {
        actionResult = nil
    }

    func containsName(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return files.contains { $0.name == name }
    }

    private func apply(_ file: SecretFileEntry) {
        if let index = files.firstIndex(where: { $0.name == file.name }) {
            files[index] = file
        } else {
            files.append(file)
        }
    }

    private func makePaginator() -> CursorPaginator<Components.Schemas.SecretFileWithCursor, SecretFileEntry> {
        let client = client
        let serviceID = serviceID
        return CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listSecretFilesForService(
                    path: .init(serviceId: serviceID),
                    query: .init(cursor: cursor, limit: limit)
                )
                .ok.body.json
        } unwrap: { envelope in
            (SecretFileEntry(envelope.secretFile), envelope.cursor)
        }
    }
}
