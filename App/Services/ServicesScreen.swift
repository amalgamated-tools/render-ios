import RenderAPI
import SwiftUI

/// The authenticated home screen: the service list for the active workspace, plus the scope
/// controls (workspace/project) and account menu around it.
///
/// Owns the `ProjectsStore` because the project scope outlives any single service list — the list
/// is re-created whenever the scope changes, the project list isn't.
struct ServicesScreen: View {
    @Bindable var authStore: AuthStore

    private let client: RenderClient
    private let ownerID: String
    @State private var projectsStore: ProjectsStore

    init(authStore: AuthStore, client: RenderClient, ownerID: String) {
        self.authStore = authStore
        self.client = client
        self.ownerID = ownerID
        _projectsStore = State(initialValue: ProjectsStore(client: client, ownerID: ownerID))
    }

    var body: some View {
        content
            .navigationTitle("Services")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !scopePicker.isEmpty {
                    ToolbarItem(placement: .topBarLeading) { scopePicker }
                }
                ToolbarItem(placement: .topBarTrailing) { accountMenu }
            }
            .task { await projectsStore.load() }
    }

    @ViewBuilder
    private var content: some View {
        // A project remembered from a previous launch only becomes a filter once the project list
        // arrives, so hold the list back rather than fetch the whole workspace and replace it.
        if projectsStore.selectedProjectID != nil && !projectsStore.hasLoaded {
            ProgressView()
        } else {
            ServicesListView(
                client: client,
                ownerID: ownerID,
                environmentIDs: projectsStore.selectedEnvironmentIDs
            )
            // Re-create the list (and its store) when the project scope changes.
            .id(projectsStore.selectedProjectID ?? "")
        }
    }

    private var scopePicker: ScopePickerView {
        ScopePickerView(authStore: authStore, projectsStore: projectsStore)
    }

    private var accountMenu: some View {
        Menu {
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                authStore.signOut()
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
    }
}
