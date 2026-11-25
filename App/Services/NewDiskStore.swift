import Foundation
import Observation
import RenderAPI

/// The Add Disk form: what it checks before sending, and the one `POST /disks` call.
///
/// The checks mirror the rules Render enforces, so a mistake shows as the user types rather than
/// after a round trip. Render's own message is shown for anything else it refuses.
@MainActor
@Observable
final class NewDiskStore {
    var name = ""
    var sizeText = "1"
    var mountPath = ""

    private(set) var isCreating = false
    /// Why Render refused the last attempt.
    private(set) var error: String?

    private let client: RenderClient
    let serviceID: String

    init(client: RenderClient, serviceID: String) {
        self.client = client
        self.serviceID = serviceID
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedMountPath: String { mountPath.trimmingCharacters(in: .whitespacesAndNewlines) }
    var sizeGB: Int? { Int(sizeText.trimmingCharacters(in: .whitespaces)) }

    /// Why the form can't be sent yet, or nil if it can.
    var validationMessage: String? {
        if trimmedName.isEmpty { return "Enter a name." }
        guard let sizeGB else { return "Enter a size in GB." }
        if sizeGB < 1 { return "A disk must be at least 1 GB." }
        if trimmedMountPath.isEmpty { return "Enter a mount path." }
        if !trimmedMountPath.hasPrefix("/") { return "The mount path must start with /." }
        return nil
    }

    /// Adds the disk. Returns the new disk's name once Render has created it, or nil on failure, with
    /// the reason in ``error``.
    func create() async -> String? {
        guard !isCreating, validationMessage == nil, let sizeGB else { return nil }
        isCreating = true
        error = nil
        defer { isCreating = false }

        do {
            let disk = try await client.api.addDisk(
                body: .json(.init(
                    name: trimmedName,
                    sizeGB: sizeGB,
                    mountPath: trimmedMountPath,
                    serviceId: serviceID
                ))
            ).created.body.json
            return disk.name
        } catch {
            self.error = RenderError.wrapping(error).errorDescription ?? "Something went wrong."
            return nil
        }
    }
}
