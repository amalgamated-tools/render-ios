import RenderAPI
import SwiftUI

/// The Postgres list for the active scope.
///
/// The scope controls and the account menu live on ``WorkspaceScreen``, which owns the
/// `ProjectsStore` and puts the same toolbar on every tab — this screen is the list and nothing
/// else. It holds the same rule as ``ServicesScreen``: the list waits for the project list when a
/// remembered project is about to filter it.
struct PostgresScreen: View {
    private let client: RenderClient
    private let ownerID: String
    @Bindable private var projectsStore: ProjectsStore

    init(client: RenderClient, ownerID: String, projectsStore: ProjectsStore) {
        self.client = client
        self.ownerID = ownerID
        self.projectsStore = projectsStore
    }

    var body: some View {
        content
            .navigationTitle("Postgres")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        // A project remembered from a previous launch only becomes a filter once the project list
        // arrives, so hold the list back rather than fetch the whole workspace and replace it.
        if projectsStore.selectedProjectID != nil && !projectsStore.hasLoaded {
            ProgressView()
        } else {
            PostgresListView(
                client: client,
                ownerID: ownerID,
                environmentIDs: projectsStore.selectedEnvironmentIDs
            )
            // Re-create the list (and its store) when the project scope changes.
            .id(projectsStore.selectedProjectID ?? "")
        }
    }
}
