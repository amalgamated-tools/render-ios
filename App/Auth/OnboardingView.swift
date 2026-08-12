import SwiftUI

/// API-key entry. Paste-friendly: a single secure field, a paste button, and a validate action that
/// calls `listOwners`. Errors surface inline (no alert spam), and a working key is only stored on
/// success.
struct OnboardingView: View {
    @Bindable var authStore: AuthStore
    @State private var apiKey = ""
    @FocusState private var keyFieldFocused: Bool

    private var isValidating: Bool { authStore.phase == .authenticating }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    VStack(alignment: .leading, spacing: 8) {
                        SecureField("rnd_…", text: $apiKey)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($keyFieldFocused)
                            .padding()
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .onSubmit(submit)
                            .disabled(isValidating)

                        if let message = authStore.errorMessage {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }

                    Button(action: submit) {
                        HStack {
                            if isValidating { ProgressView().tint(.white) }
                            Text(isValidating ? "Validating…" : "Continue")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isValidating)

                    footer
                }
                .padding()
            }
            .navigationTitle("Render")
            .onAppear { keyFieldFocused = true }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.tint)
            Text("Connect your account")
                .font(.title2.bold())
            Text("Paste a Render API key to see your services. The key is stored only in your device's Keychain.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Link(destination: URL(string: "https://dashboard.render.com/u/settings/api-keys")!) {
            Label("Create an API key on the Render dashboard", systemImage: "arrow.up.right.square")
                .font(.footnote)
        }
    }

    private func submit() {
        keyFieldFocused = false
        Task { await authStore.signIn(apiKey: apiKey) }
    }
}
