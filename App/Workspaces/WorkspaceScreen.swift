import RenderAPI
import SwiftUI

/// The authenticated home: everything in one workspace, split into tabs.
///
/// Tabs arrived with env groups, which are the first resource in the app that belongs to the
/// *workspace* rather than to a service — there is no service-side listing of them, so they can't be a
/// drill-down. A second toolbar item on the service list would have hidden them; Phase 5c's datastores
/// (Postgres and Key Value) live here for the same reason.
///
/// This screen owns what is per-workspace rather than per-list: the scope picker, the account menu, and
/// the `ProjectsStore` behind them. Every tab then agrees about the active scope, and switching tabs
/// doesn't re-fetch the project list.
struct WorkspaceScreen: View {
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
        TabView {
            Tab("Services", systemImage: "square.stack.3d.up") {
                NavigationStack {
                    ServicesScreen(client: client, ownerID: ownerID, projectsStore: projectsStore)
                        .toolbar { sharedToolbar }
                }
            }
            Tab("Postgres", systemImage: "cylinder.split.1x2") {
                NavigationStack {
                    PostgresScreen(client: client, ownerID: ownerID, projectsStore: projectsStore)
                        .toolbar { sharedToolbar }
                }
            }
            Tab("Key Value", systemImage: "bolt.horizontal.circle") {
                NavigationStack {
                    KeyValueScreen(client: client, ownerID: ownerID, projectsStore: projectsStore)
                        .toolbar { sharedToolbar }
                }
            }
            Tab("Env Groups", systemImage: "rectangle.stack") {
                NavigationStack {
                    EnvGroupsListView(client: client, ownerID: ownerID)
                        .toolbar { sharedToolbar }
                }
            }
        }
        .task { await projectsStore.load() }
    }

    /// The scope picker and account menu, on both tabs. A picker that appeared on one tab and not the
    /// other would make the active scope look like a property of the list rather than of the session.
    ///
    /// The picker takes the **title** slot rather than a leading one. In the leading slot it crowded the
    /// inline title into "Servic…" on one tab and pushed it off the bar entirely on the other — and the
    /// title was redundant anyway, since the tab bar names both screens. The workspace is the more useful
    /// thing to read there. (`navigationTitle` is still set on each screen: it's what a pushed screen's
    /// back button says.)
    @ToolbarContentBuilder
    private var sharedToolbar: some ToolbarContent {
        if !scopePicker.isEmpty {
            ToolbarItem(placement: .principal) { scopePicker }
        }
        ToolbarItem(placement: .topBarTrailing) { accountMenu }
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
