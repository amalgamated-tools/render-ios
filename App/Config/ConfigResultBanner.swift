import SwiftUI

/// The outcome banner both config screens show, with the **Deploy** affordance on a success.
///
/// Shared rather than written twice: the env var and secret file screens reported identically
/// already, and the deploy path — confirmation copy, in-flight state, what the button says on an
/// image-backed service — is more than either screen should be carrying its own copy of.
struct ConfigResultBanner: View {
    let result: ConfigActionResult
    /// `nil` when this service can't be deployed (a cron job), in which case no button is offered.
    let deployer: ConfigDeployer?
    let deploy: () async -> Void
    let dismiss: () -> Void

    @State private var isConfirmingDeploy = false

    /// The button appears only on a saved-but-not-live result, and only while nothing is in flight.
    private var offeredDeployer: ConfigDeployer? {
        result.offersDeploy ? deployer : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: result.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                Text(result.message)
                    .font(.subheadline)
                Spacer()
                Button("Dismiss", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
            }
            // Tint the message, not the whole banner: a green Deploy button would read as a status
            // rather than as something to press.
            .foregroundStyle(result.isFailure ? .red : .green)

            if let deployer = offeredDeployer {
                HStack {
                    Spacer()
                    if deployer.isDeploying {
                        ProgressView()
                    } else {
                        // Confirmed like every other action that touches a live service — this one
                        // is one tap from a banner, which is exactly why it isn't one tap from a
                        // build. The dialog names the service, since the banner doesn't.
                        Button(deployer.action.title, systemImage: deployer.action.systemImage) {
                            isConfirmingDeploy = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog(
            offeredDeployer.map { $0.action.confirmationTitle(serviceName: $0.serviceName) } ?? "",
            isPresented: $isConfirmingDeploy,
            titleVisibility: .visible
        ) {
            if let deployer = offeredDeployer {
                Button(deployer.action.title) {
                    Task { await deploy() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let deployer = offeredDeployer {
                Text(deployer.action.confirmationMessage)
            }
        }
    }
}
