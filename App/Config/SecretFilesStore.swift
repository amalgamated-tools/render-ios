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

/// Reads and writes a set of secret files — a service's own, or an env group's.
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
/// A second, uglier difference lives in ``SecretFileBackend``: the service-scoped write endpoint
/// doesn't match its own spec, so it's the one write in the app that applies what it *sent*.
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

    private let backend: SecretFileBackend

    var scope: ConfigScope { backend.scope }

    init(backend: SecretFileBackend, deployer: ConfigDeployer? = nil) {
        self.backend = backend
        self.deployer = deployer
    }

    /// A service's own secret files. The common case, and the only one that can offer a deploy.
    convenience init(
        client: RenderClient,
        serviceID: String,
        deployer: ConfigDeployer? = nil,
        pageSize: Int = 100
    ) {
        self.init(
            backend: .service(client: client, serviceID: serviceID, pageSize: pageSize),
            deployer: deployer
        )
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
            files = try await backend.load()
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
            switch try await backend.save(name, content) {
            case .entry(let file):
                apply(file)
            case .wholeSet(let files):
                self.files = files
            }
            actionResult = .success(
                "\(name) saved. \(backend.scope.takesEffectNote)",
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
            try await backend.delete(name)
            files.removeAll { $0.name == name }
            actionResult = .success(
                "\(name) deleted. \(backend.scope.takesEffectNote)",
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
}
