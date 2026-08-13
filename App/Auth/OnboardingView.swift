import SwiftUI

/// Sign-in. The primary path is the OAuth device flow — one tap, approve in the browser. Pasting
/// an API key remains as a collapsed fallback: same validation as before (a `listOwners` call),
/// errors inline, and a working key only stored on success.
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
                VStack(alignment: .leading, spacing: 20) {
                    header

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(.logomark)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(.tint)
                .matchedGeometryEffect(id: SplashView.markID, in: brandNamespace)
            Text("Connect your account")
                .font(.title2.bold())
            Text("Approve this device in your browser to see your services. Credentials are stored only in your device's Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
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
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
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
