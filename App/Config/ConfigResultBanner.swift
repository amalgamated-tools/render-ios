import SwiftUI

/// The outcome banner both config screens show, with the **Deploy** affordance on a success.
///
/// Shared rather than written twice: the env var and secret file screens reported identically
/// already, and the deploy path — confirmation copy, in-flight state, what the button says on an
/// image-backed service — is more than either screen should be carrying its own copy of.
/// Anything a screen reports in an outcome banner.
///
/// Five stores independently grew the same `{ id, message, isFailure }` shape. They are not worth
/// merging — each is tied to a different action type and reloads different state — but they can
/// share the one behaviour that should not be written five times.
protocol ActionOutcome: Equatable {
    var isFailure: Bool { get }
}

extension ConfigActionResult: ActionOutcome {}

extension View {
    /// Haptic and spring for an action's outcome banner.
    ///
    /// Applied to the screen rather than to the banner itself, because the banner only exists once
    /// there is a result — a trigger inside it would never see the nil-to-value change that fires
    /// the feedback.
    ///
    /// A restart or a rollback is a real-world side effect, confirmed in a dialog and then reported
    /// in a banner at the opposite end of the screen from the menu that started it. The haptic is
    /// what tells you it landed without having to look for the answer.
    func actionOutcomeFeedback<Outcome: ActionOutcome>(_ result: Outcome?) -> some View {
        sensoryFeedback(trigger: result) { _, new in
            guard let new else { return nil }
            return new.isFailure ? .error : .success
        }
        .animation(.spring(duration: 0.35), value: result)
    }
}

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
