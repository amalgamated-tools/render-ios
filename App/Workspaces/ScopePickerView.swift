import SwiftUI

/// The list-scope switcher in the list toolbar: which workspace, and optionally which project
/// within it. Shown only when there's something to switch between (more than one workspace, or at
/// least one project). Changing either reloads the list against the new scope.
struct ScopePickerView: View {
    @Bindable var authStore: AuthStore
    @Bindable var projectsStore: ProjectsStore

    /// Nothing to pick from — one workspace and no projects — so the control is hidden entirely.
    var isEmpty: Bool {
        authStore.owners.count <= 1 && projectsStore.projects.isEmpty
    }

    var body: some View {
        Menu {
            if authStore.owners.count > 1 {
                Picker("Workspace", selection: $authStore.selectedOwnerID) {
                    ForEach(authStore.owners) { owner in
                        Label(owner.name, systemImage: owner.isTeam ? "person.3" : "person")
                            .tag(String?.some(owner.id))
                    }
                }
            }
            // A second picker, so the two scopes land in their own menu sections. (UIKit drops
            // `Section` titles inside a menu, hence the person/folder icons carrying the
            // distinction instead.)
            if !projectsStore.projects.isEmpty {
                Picker("Project", selection: $projectsStore.selectedProjectID) {
                    Text("All Projects").tag(String?.none)
                    ForEach(projectsStore.projects) { project in
                        Label(project.name, systemImage: "folder")
                            .tag(String?.some(project.id))
                    }
                }
            }
        } label: {
            // An explicit HStack rather than a Label: the toolbar drops a Label's title when space
            // is tight, and the scope name is the point of the control.
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
            }
            .font(.subheadline)
        }
    }

    /// The narrower of the two scopes, since that's what the list is actually showing.
    private var title: String {
        projectsStore.selectedProject?.name ?? selectedOwnerName
    }

    private var selectedOwnerName: String {
        authStore.owners.first { $0.id == authStore.selectedOwnerID }?.name ?? "Workspace"
    }
}
