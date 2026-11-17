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
    @State private var accountStore: AccountStore
    /// A value-based path, so a tapped failure notification can push a service the list hasn't
    /// loaded — see ``ServiceRoute`` — and then the event that failed on top of it. A
    /// `NavigationPath` rather than an array because those are two different route types.
    @State private var servicesPath = NavigationPath()
    @State private var selectedTab: WorkspaceTab = .services
    @State private var isShowingNotificationSettings = false
    @State private var isShowingWebhooks = false
    @Environment(NotificationRouter.self) private var router

    private enum WorkspaceTab: Hashable {
        case services, postgres, keyValue, envGroups
    }

    init(authStore: AuthStore, client: RenderClient, ownerID: String) {
        self.authStore = authStore
        self.client = client
        self.ownerID = ownerID
        _projectsStore = State(initialValue: ProjectsStore(client: client, ownerID: ownerID))
        _accountStore = State(initialValue: AccountStore(client: client))
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Services", systemImage: "square.stack.3d.up", value: .services) {
                NavigationStack(path: $servicesPath) {
                    ServicesScreen(client: client, ownerID: ownerID, projectsStore: projectsStore)
                        .navigationDestination(for: ServiceRoute.self) { route in
                            ServiceDetailView(
                                client: client,
                                ownerID: ownerID,
                                serviceID: route.id,
                                serviceName: route.name
                            )
                        }
                        .navigationDestination(for: EventRoute.self) { route in
                            EventDetailView(client: client, eventID: route.id)
                        }
                        .toolbar { sharedToolbar }
                }
            }
            Tab("Postgres", systemImage: "cylinder.split.1x2", value: .postgres) {
                NavigationStack {
                    PostgresScreen(client: client, ownerID: ownerID, projectsStore: projectsStore)
                        .toolbar { sharedToolbar }
                }
            }
            Tab("Key Value", systemImage: "bolt.horizontal.circle", value: .keyValue) {
                NavigationStack {
                    KeyValueScreen(client: client, ownerID: ownerID, projectsStore: projectsStore)
                        .toolbar { sharedToolbar }
                }
            }
            Tab("Env Groups", systemImage: "rectangle.stack", value: .envGroups) {
                NavigationStack {
                    EnvGroupsListView(client: client, ownerID: ownerID)
                        .toolbar { sharedToolbar }
                }
            }
        }
        .task { await projectsStore.load() }
        .task { await accountStore.load() }
        // Runs on appearance *and* on every change, which is what makes the two-step workspace
        // switch below work: the switch rebuilds this screen, and the rebuilt one re-reads the same
        // still-pending target.
        .task(id: router.pending) { openPendingNotification() }
        .sheet(isPresented: $isShowingNotificationSettings) {
            NotificationSettingsView(client: client, ownerID: ownerID)
        }
        .sheet(isPresented: $isShowingWebhooks) {
            WebhooksView(client: client, ownerID: ownerID)
        }
    }

    /// Navigates to whatever a tapped notification asked for.
    ///
    /// A notification can name a service in a workspace other than the active one. Switching
    /// `selectedOwnerID` re-creates this whole screen (`RootView` keys it on the owner), so the
    /// target is left pending rather than consumed — the rebuilt screen picks it up and navigates.
    private func openPendingNotification() {
        guard let target = router.pending else { return }
        guard target.ownerID == ownerID else {
            // Only switch to a workspace this credential actually has. Otherwise drop the target,
            // rather than leave it pending forever and re-fire on every navigation.
            if authStore.owners.contains(where: { $0.id == target.ownerID }) {
                authStore.selectedOwnerID = target.ownerID
            } else {
                router.consume()
            }
            return
        }
        selectedTab = .services
        var path = NavigationPath()
        path.append(ServiceRoute(id: target.serviceID, name: target.serviceName))
        if let eventID = target.eventID {
            path.append(EventRoute(id: eventID))
        }
        servicesPath = path
        router.consume()
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
            // Who's signed in — the name as the section title, the email as a disabled row. Shown
            // only once known; see ``AccountStore`` for why there's no loading or error state.
            if let user = accountStore.user {
                Section(user.name) {
                    Text(user.email)
                }
            }
            Button("Notifications", systemImage: "bell") {
                isShowingNotificationSettings = true
            }
            Button("Webhooks", systemImage: "point.3.connected.trianglepath.dotted") {
                isShowingWebhooks = true
            }
            // Clearing the watchlist is `AuthStore`'s job, via `onSessionEnded` — doing it here
            // would only cover the sessions that end because someone tapped this.
            Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                authStore.signOut()
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
    }
}
