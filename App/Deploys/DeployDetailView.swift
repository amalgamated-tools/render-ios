import RenderAPI
import SwiftUI

/// One deploy in full. Opens with the copy the history list already has, then refetches
/// `GET /services/{id}/deploys/{deployId}` so an in-progress deploy shows its current status rather
/// than whatever it was when the list loaded.
struct DeployDetailView: View {
    @State private var deploy: DeploySummary
    @State private var errorMessage: String?

    private let client: RenderClient
    private let serviceID: String

    init(client: RenderClient, serviceID: String, deploy: DeploySummary) {
        self.client = client
        self.serviceID = serviceID
        _deploy = State(initialValue: deploy)
    }

    var body: some View {
        List {
            Section {
                if let status = deploy.status {
                    DeployStatusChip(status: status)
                }
                if let trigger = deploy.trigger {
                    LabeledContent("Trigger", value: trigger.displayName)
                }
                if let timestamp = deploy.timestamp {
                    LabeledContent("When", value: timestamp.formatted(date: .abbreviated, time: .shortened))
                }
                if let duration = deploy.duration {
                    LabeledContent("Duration", value: DeployRow.durationFormat(duration))
                }
            }

            if deploy.commitID != nil || deploy.commitMessage != nil {
                Section("Commit") {
                    if let shortCommitID = deploy.shortCommitID {
                        LabeledContent("SHA", value: shortCommitID).monospaced()
                    }
                    if let message = deploy.commitMessage {
                        Text(message)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }
                    if let commitCreatedAt = deploy.commitCreatedAt {
                        LabeledContent("Authored", value: commitCreatedAt.formatted(date: .abbreviated, time: .shortened))
                    }
                }
            }

            if let imageRef = deploy.imageRef {
                Section("Image") {
                    Text(imageRef).font(.footnote).monospaced().textSelection(.enabled)
                }
            }

            Section {
                LabeledContent("Deploy ID", value: deploy.id)
                    .font(.footnote)
                    .monospaced()
                    .textSelection(.enabled)
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Deploy")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        do {
            let fetched = try await client.api
                .retrieveDeploy(path: .init(serviceId: serviceID, deployId: deploy.id))
                .ok.body.json
            deploy = DeploySummary(fetched)
            errorMessage = nil
        } catch {
            // The screen already has a usable copy from the list, so a failed refresh is a footnote,
            // not an empty state.
            errorMessage = RenderError.wrapping(error).errorDescription
        }
    }
}
