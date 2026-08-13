import SwiftUI
import UIKit

/// The waiting room of the OAuth device flow: shows the code the user will see echoed in the
/// browser, opens the pre-filled authorization page, and sits on a spinner while `AuthStore`
/// polls for approval. Approval flips the phase to `.authenticated`, so this view just disappears.
struct DeviceAuthorizationView: View {
    @Bindable var authStore: AuthStore
    let userCode: String
    let verificationURL: URL

    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    codeCard
                    Button {
                        openURL(verificationURL)
                    } label: {
                        Label("Open render.com to approve", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Waiting for approval…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)

                    Button("Cancel", role: .cancel) {
                        authStore.cancelDeviceAuthorization()
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
            }
            .navigationTitle("Render")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The same mark as onboarding, at the same size, so crossing into the device flow
            // doesn't feel like leaving the app for a system sheet.
            Image(.logomark)
                .resizable()
                .scaledToFit()
                .frame(height: 36)
                .foregroundStyle(.tint)
            Text("Approve this device")
                .font(.title2.bold())
            Text("Render will show this code while you approve. Make sure it matches before you tap Authorize.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var codeCard: some View {
        VStack(spacing: 12) {
            Text(userCode)
                .font(.system(.largeTitle, design: .monospaced).bold())
                .tracking(2)
                .textSelection(.enabled)
            Button {
                UIPasteboard.general.string = userCode
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.footnote)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

#Preview {
    DeviceAuthorizationView(
        authStore: AuthStore(),
        userCode: "WXYZ-9876",
        verificationURL: URL(string: "https://render.com/device")!
    )
}
