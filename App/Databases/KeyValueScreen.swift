import RenderAPI
import SwiftUI

/// The Key Value list for the active scope. Same shape as ``PostgresScreen``.
struct KeyValueScreen: View {
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
            .navigationTitle("Key Value")
            .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        // A project remembered from a previous launch only becomes a filter once the project list
        // arrives, so hold the list back rather than fetch the whole workspace and replace it.
        if projectsStore.selectedProjectID != nil && !projectsStore.hasLoaded {
            SkeletonList()
        } else {
            KeyValueListView(
                client: client,
                ownerID: ownerID,
                environmentIDs: projectsStore.selectedEnvironmentIDs
            )
            // Re-create the list (and its store) when the project scope changes.
            .id(projectsStore.selectedProjectID ?? "")
        }
    }
}
