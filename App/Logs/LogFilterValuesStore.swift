import Foundation
import Observation
import RenderAPI

/// Loads the vocabulary for each filter facet from `GET /logs/values`.
///
/// The values are per workspace and per resource — one service emits `level: error`, another emits
/// `level: err` — so offering a hard-coded list would mean offering filters that match nothing. Six
/// independent calls, run concurrently and rendered as they're needed; a facet that fails or comes
/// back empty simply isn't offered, because there's nothing to pick.
@MainActor
@Observable
final class LogFilterValuesStore {
    private(set) var values: [LogFilter.Facet: [String]] = [:]
    private(set) var isLoading = false
    private(set) var hasLoaded = false

    private let client: RenderClient
    private let ownerID: String
    private let resourceIDs: [String]

    init(client: RenderClient, ownerID: String, resourceIDs: [String]) {
        self.client = client
        self.ownerID = ownerID
        self.resourceIDs = resourceIDs
    }

    /// Values for a facet, plus anything already selected that the API didn't report — otherwise an
    /// active filter could vanish from the sheet and become impossible to clear.
    func options(for facet: LogFilter.Facet, selected: Set<String>) -> [String] {
        let known = values[facet] ?? []
        return Array(Set(known).union(selected)).sorted()
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }

        let client = client
        let ownerID = ownerID
        let resourceIDs = resourceIDs
        let loaded = await withTaskGroup(of: (LogFilter.Facet, [String]).self) { group in
            for facet in LogFilter.Facet.allCases {
                group.addTask {
                    do {
                        let values = try await client.api.listLogsValues(
                            query: .init(ownerId: ownerID, label: facet.label, resource: resourceIDs)
                        ).ok.body.json
                        return (facet, values.filter { !$0.isEmpty }.sorted())
                    } catch {
                        // A facet we couldn't enumerate is a facet we don't show. Six spinners and
                        // six error rows would be a worse sheet than five working filters.
                        return (facet, [])
                    }
                }
            }
            var collected: [LogFilter.Facet: [String]] = [:]
            for await (facet, values) in group {
                collected[facet] = values
            }
            return collected
        }
        values = loaded
    }
}
