import Foundation
import Observation
import RenderAPI

/// Loads and pages one service's deploy history.
///
/// Same shape as `ServicesStore`: a page at a time via `CursorPaginator.firstPage`, appended as the
/// user scrolls.
@MainActor
@Observable
final class DeploysStore {
    private(set) var deploys: [DeploySummary] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var hasMore = true

    private let client: RenderClient
    private let serviceID: String
    private let pageSize: Int
    private var nextCursor: String?

    init(client: RenderClient, serviceID: String, pageSize: Int = 20) {
        self.client = client
        self.serviceID = serviceID
        self.pageSize = pageSize
    }

    func refresh() async {
        deploys = []
        nextCursor = nil
        hasMore = true
        errorMessage = nil
        await loadNextPage()
    }

    func loadNextPage() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let page = try await Self.paginator(client: client, serviceID: serviceID, pageSize: pageSize)
                .firstPage(after: nextCursor)
            deploys.append(contentsOf: page.elements)
            nextCursor = page.nextCursor
            hasMore = page.nextCursor != nil
        } catch {
            errorMessage = RenderError.wrapping(error).errorDescription
            hasMore = false
        }
    }

    /// One envelope's worth of deploy history, with the spec's optionality resolved.
    ///
    /// `deployWithCursor` marks both members optional even though the API always sends both;
    /// an envelope missing either is dropped, which at worst ends paging a page early.
    struct Envelope: Sendable {
        let deploy: Components.Schemas.Deploy
        let cursor: String
    }

    static func paginator(
        client: RenderClient,
        serviceID: String,
        pageSize: Int
    ) -> CursorPaginator<Envelope, DeploySummary> {
        CursorPaginator(pageSize: pageSize) { cursor, limit in
            try await client.api
                .listDeploys(
                    path: .init(serviceId: serviceID),
                    query: .init(cursor: cursor, limit: limit)
                )
                .ok.body.json
                .compactMap { envelope in
                    guard let deploy = envelope.deploy, let cursor = envelope.cursor else { return nil }
                    return Envelope(deploy: deploy, cursor: cursor)
                }
        } unwrap: { envelope in
            (DeploySummary(envelope.deploy), envelope.cursor)
        }
    }

    /// The newest deploy, or `nil` when the service has never deployed. Used by the detail screen,
    /// which needs current status without the whole history.
    static func latestDeploy(client: RenderClient, serviceID: String) async throws -> DeploySummary? {
        try await paginator(client: client, serviceID: serviceID, pageSize: 1)
            .firstPage()
            .elements
            .first
    }
}
