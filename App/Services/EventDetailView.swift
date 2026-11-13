import RenderAPI
import SwiftUI

/// What happened, when, and — for a failure — why. The screen a failure notification opens on.
struct EventDetailView: View {
    @State private var store: EventDetailStore

    init(client: RenderClient, eventID: String, preview: ServiceEvent? = nil) {
        _store = State(initialValue: EventDetailStore(client: client, eventID: eventID, preview: preview))
    }

    var body: some View {
        List {
            if let event = store.event {
                summary(event)
                if let failure = event.details.failure {
                    cause(failure)
                }
                related(event.details)
            }
            if let raw = store.rawDetails {
                Section("Details") {
                    Text(raw)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
            if let message = store.errorMessage, store.event != nil {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
        .overlay {
            if store.event == nil {
                if let message = store.errorMessage {
                    ErrorStateView(subject: "this event", message: message) { await store.load() }
                } else {
                    ProgressView()
                }
            }
        }
    }

    private func summary(_ event: ServiceEvent) -> some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: event.type.systemImage)
                    .font(.title2)
                    .foregroundStyle(event.type.tint)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.type.displayName)
                        .font(.headline)
                    if let reason = event.reasonSummary {
                        Text(reason)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func cause(_ failure: EventFailure) -> some View {
        Section {
            if let limit = failure.memoryLimit {
                LabeledContent("Out of memory", value: limit.isEmpty ? "Yes" : "\(limit) limit")
            }
            if let code = failure.nonZeroExit {
                LabeledContent("Exit status", value: "\(code)")
            }
            if failure.evicted {
                LabeledContent("Evicted", value: failure.evictionReason ?? "Yes")
            }
            if let seconds = failure.timedOutSeconds {
                LabeledContent("Timed out after", value: Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds])))
            }
            if let reason = failure.timedOutReason {
                LabeledContent("Timeout reason", value: reason)
            }
            if let unhealthy = failure.unhealthy, !unhealthy.isEmpty {
                LabeledContent("Health check", value: unhealthy)
            }
            if failure.earlyExit == true {
                LabeledContent("Exited early", value: "Yes")
            }
        } header: {
            Text("Cause")
        } footer: {
            if failure.memoryLimit != nil {
                Text("The instance used more memory than its plan allows. A larger instance type, or less memory per process, fixes this — the code may not have a bug.")
            }
        }
    }

    @ViewBuilder
    private func related(_ details: EventDetails) -> some View {
        let rows: [(String, String)] = [
            ("Deploy", details.deployID),
            ("Deploy status", details.deployStatus?.capitalized),
            ("Build", details.buildID),
            ("Build status", details.buildStatus?.capitalized),
            ("Instance", details.instanceID),
            ("Run status", details.runStatus?.capitalized),
            ("Reason", details.reasonText),
        ].compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }

        if !rows.isEmpty {
            Section("Related") {
                ForEach(rows, id: \.0) { label, value in
                    LabeledContent(label) {
                        Text(value)
                            .font(label.hasSuffix("status") || label == "Reason" ? .body : .caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }
}
