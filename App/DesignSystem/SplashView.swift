import SwiftUI

/// The first frame SwiftUI draws, built to be pixel-identical to the launch screen.
///
/// `matchedGeometryEffect` cannot reach across the launch screen — that is a separate, process-owned
/// UIKit view, torn down before `WindowGroup` renders, so there is no geometry on the other side to
/// match against. The technique that does work is plain reproduction: draw the same mark, at the
/// same size, on the same background, and the handoff has nothing to see. Everything after that is
/// animated away from a state the system already put on screen.
///
/// Two values here are a contract with things outside this file. ``logoSize`` must equal the point
/// size `Scripts/make-brand-assets.swift` bakes into `LaunchLogomark`, because `UILaunchScreen`
/// draws its image at natural size and never scales it. And the background must be the same colour
/// set `Resources/Info.plist` names. Break either and the launch visibly jumps.
struct SplashView: View {
    /// 96pt — the size `LaunchLogomark` is authored at.
    static let logoSize: CGFloat = 96

    var namespace: Namespace.ID
    /// Set once the app is ready, to animate the mark out rather than cut it.
    var isSettling: Bool

    var body: some View {
        ZStack {
            Color(.launchBackground)
                .ignoresSafeArea()

            Image(.launchLogomark)
                .resizable()
                .scaledToFit()
                .frame(width: Self.logoSize, height: Self.logoSize)
                .matchedGeometryEffect(id: SplashView.markID, in: namespace)
                .scaleEffect(isSettling ? 0.92 : 1)
                .opacity(isSettling ? 0 : 1)
        }
        // Not just for the background. `UIImageRespectsSafeAreaInsets` is false in Info.plist, so
        // the launch screen centres the mark on the whole display, while a stack laid out inside
        // the safe area would centre it between a 59pt status bar and a 34pt home indicator — about
        // 12pt lower. That is small enough to look like a bug rather than a design, which is
        // precisely the jump this view exists to avoid.
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Render")
    }

    /// Shared with the onboarding header so the mark flies into place rather than cross-fading.
    static let markID = "brandmark"
}
