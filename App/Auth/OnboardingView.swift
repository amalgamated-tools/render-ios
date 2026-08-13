import SwiftUI

/// Sign-in. The primary path is the OAuth device flow — one tap, approve in the browser. Pasting
/// an API key remains as a collapsed fallback: same validation as before (a `listOwners` call),
/// errors inline, and a working key only stored on success.
///
/// This is the first screen anyone sees, so it carries the brand: the mark arrives here from the
/// splash on a violet panel, and three capability rows say what the app is actually for. The panel
/// is the one place in the app that spends real colour; everything past sign-in is a dense
/// operational list where a gradient would be noise.
struct OnboardingView: View {
    @Bindable var authStore: AuthStore
    /// Shared with ``SplashView`` so the logomark flies from the splash into this header rather
    /// than cross-fading between two unrelated positions.
    var brandNamespace: Namespace.ID
    @State private var apiKey = ""
    @State private var showsAPIKeyEntry = false
    @FocusState private var keyFieldFocused: Bool

    private var isBusy: Bool { authStore.phase == .authenticating }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    hero
                    capabilities

                    if let message = authStore.errorMessage {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await authStore.beginDeviceAuthorization() }
                    } label: {
                        HStack {
                            if isBusy && !showsAPIKeyEntry { ProgressView().tint(.white) }
                            Text("Sign in with Render")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isBusy)

                    apiKeyFallback
                }
                .padding()
            }
            .navigationTitle("Render")
        }
    }

    private var hero: some View {
        VStack(spacing: Theme.Spacing.row) {
            Image(.logomark)
                .resizable()
                .scaledToFit()
                .frame(height: 56)
                // Template artwork, so this is what paints it — white knocked out of the gradient.
                .foregroundStyle(.white)
                .matchedGeometryEffect(id: SplashView.markID, in: brandNamespace)

            Text("Your services, in your pocket")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            Theme.brandGradient,
            in: RoundedRectangle(cornerRadius: Theme.Radius.hero, style: .continuous)
        )
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.row) {
            Text("Connect your account")
                .font(.title2.bold())
            Text("Approve this device in your browser. Credentials are stored only in your device's Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.tight) {
                capability("Deploys", "Watch a deploy land, or roll one back", "arrow.triangle.2.circlepath")
                capability("Logs", "Live tail with filters and search", "text.alignleft")
                capability("Metrics", "CPU, memory, and traffic at a glance", "chart.xyaxis.line")
            }
            .padding(.top, 4)
        }
    }

    private func capability(_ title: String, _ detail: String, _ systemImage: String) -> some View {
        HStack(spacing: Theme.Spacing.row) {
            GlyphTile(systemImage: systemImage, tint: Color(.accent), size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var apiKeyFallback: some View {
        DisclosureGroup("Use an API key instead", isExpanded: $showsAPIKeyEntry) {
            VStack(alignment: .leading, spacing: 12) {
                SecureField("rnd_…", text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($keyFieldFocused)
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .onSubmit(submit)
                    .disabled(isBusy)

                Button(action: submit) {
                    HStack {
                        if isBusy && showsAPIKeyEntry { ProgressView() }
                        Text(isBusy && showsAPIKeyEntry ? "Validating…" : "Continue")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)

                Link(destination: URL(string: "https://dashboard.render.com/u/settings/api-keys")!) {
                    Label("Create an API key on the Render dashboard", systemImage: "arrow.up.right.square")
                        .font(.footnote)
                }
            }
            .padding(.top, 8)
        }
        .font(.subheadline)
        .onChange(of: showsAPIKeyEntry) { _, expanded in
            keyFieldFocused = expanded
        }
    }

    private func submit() {
        keyFieldFocused = false
        Task { await authStore.signIn(apiKey: apiKey) }
    }
}
