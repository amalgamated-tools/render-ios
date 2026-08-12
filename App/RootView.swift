import RenderAPI
import SwiftUI

/// App entry point. Switches between onboarding and the service list on `AuthStore` state, and
/// revalidates any stored key on launch.
struct RootView: View {
    @State private var authStore = AuthStore()

    var body: some View {
        content
            .task { await authStore.restore() }
    }

    @ViewBuilder
    private var content: some View {
        switch authStore.phase {
        case .restoring:
            ProgressView("Connecting…")
        case .needsKey, .authenticating:
            OnboardingView(authStore: authStore)
        case .authenticated:
            authenticatedView
        }
    }

    @ViewBuilder
    private var authenticatedView: some View {
        if let ownerID = authStore.selectedOwnerID {
            NavigationStack {
                ServicesListView(client: authStore.authenticatedClient(), ownerID: ownerID)
                    .navigationTitle("Services")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        if authStore.owners.count > 1 {
                            ToolbarItem(placement: .topBarLeading) {
                                OwnerPickerView(authStore: authStore)
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                Button("Sign Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                                    authStore.signOut()
                                }
                            } label: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                    }
            }
            // Re-create the list (and its store) when the active workspace changes.
            .id(ownerID)
        } else {
            ContentUnavailableView("No Workspace", systemImage: "person.slash")
        }
    }
}

#Preview {
    RootView()
}
