import RenderAPI
import SwiftUI

/// App entry point. Shows the splash until the stored credential has been revalidated, then
/// switches between onboarding and the service list on `AuthStore` state.
struct RootView: View {
    @State private var authStore = AuthStore()
    /// Deliberately its own state rather than `phase == .restoring`. `AuthStore` re-enters
    /// `.restoring` on sign-out, and re-showing the splash mid-session would read as a crash-restart.
    @State private var isSplashComplete = false
    @State private var isSettling = false
    @Namespace private var brand
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How long the mark stays up at minimum. `restore()` is a Keychain read plus one `listOwners`
    /// call and often finishes in well under 100ms; a splash that disappears in two frames looks
    /// like a rendering fault rather than a brand.
    private static let minimumSplashDuration = Duration.milliseconds(700)

    var body: some View {
        ZStack {
            if isSplashComplete {
                content
                    .transition(.opacity)
            } else {
                SplashView(namespace: brand, isSettling: isSettling)
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .task { await openApp() }
    }

    /// Restores the session and dismisses the splash, whichever finishes last.
    private func openApp() async {
        // A floor, not a delay: a slow restore takes exactly as long as it takes, and only a fast
        // one waits. Sleeping *then* restoring would add 700ms to every launch.
        async let restored: Void = authStore.restore()
        async let floor: Void = Task.sleep(for: Self.minimumSplashDuration)
        _ = await (restored, try? floor)

        guard !reduceMotion else {
            isSplashComplete = true
            return
        }
        withAnimation(.easeIn(duration: 0.22)) { isSettling = true }
        try? await Task.sleep(for: .milliseconds(120))
        withAnimation(.easeOut(duration: 0.28)) { isSplashComplete = true }
    }

    @ViewBuilder
    private var content: some View {
        switch authStore.phase {
        case .restoring:
            // Unreachable on launch — the splash covers it — but sign-out passes back through here.
            ProgressView("Connecting…")
        case .needsKey, .authenticating:
            OnboardingView(authStore: authStore, brandNamespace: brand)
        case .awaitingAuthorization(let userCode, let verificationURL):
            DeviceAuthorizationView(
                authStore: authStore,
                userCode: userCode,
                verificationURL: verificationURL
            )
        case .authenticated:
            authenticatedView
        }
    }

    @ViewBuilder
    private var authenticatedView: some View {
        if let ownerID = authStore.selectedOwnerID {
            // The navigation stacks live inside, one per tab.
            WorkspaceScreen(authStore: authStore, client: authStore.authenticatedClient(), ownerID: ownerID)
                // Re-create the screen (and its stores) when the active workspace changes.
                .id(ownerID)
        } else {
            ContentUnavailableView("No Workspace", systemImage: "person.slash")
        }
    }
}

#Preview {
    RootView()
}
