import RenderAPI
import SwiftUI

/// One job in full. Reads from the list's store, so a cancel here shows in the list behind it, and
/// the list's polling keeps this screen current while the job runs.
struct JobDetailView: View {
    let store: JobsStore
    let jobID: String
    let serviceName: String

    @State private var pendingCancel: JobSummary?

    var body: some View {
        List {
            if let job = store.job(id: jobID) {
                Section {
                    JobStatusChip(status: job.status)
                    LabeledContent("Created", value: job.createdAt.formatted(date: .abbreviated, time: .standard))
                    if let startedAt = job.startedAt {
                        LabeledContent("Started", value: startedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let finishedAt = job.finishedAt {
                        LabeledContent("Finished", value: finishedAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let duration = job.duration {
                        LabeledContent("Duration", value: DeployRow.durationFormat(duration))
                    }
                }

                Section("Command") {
                    Text(job.startCommand)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }

                if job.isActive {
                    Section {
                        Button("Cancel Job", systemImage: "xmark.circle", role: .destructive) {
                            pendingCancel = job
                        }
                        .disabled(store.writeInFlight != nil)
                    }
                }

                // No Plan row: Render returns an internal ID (`plan-srv-006`), not a plan name.
                Section {
                    LabeledContent("Job ID", value: job.id)
                }
                .font(.footnote.monospaced())
                .textSelection(.enabled)
            }
        }
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.reread(jobID: jobID) }
        .task {
            // The store is shared with the list, so a "Job started." from there would otherwise
            // follow you onto this screen. Only this screen's own outcomes belong here.
            store.dismissActionResult()
            await store.reread(jobID: jobID)
        }
        .safeAreaInset(edge: .bottom) { JobActionBanner(store: store) }
        .jobCancelConfirmation(job: $pendingCancel, store: store)
    }
}
