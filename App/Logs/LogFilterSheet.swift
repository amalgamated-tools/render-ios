import RenderAPI
import SwiftUI

/// Edits the server-side log filters.
///
/// Changes are applied on **Apply**, not as you type: every edit re-runs the query and restarts the
/// live socket, so live-binding the form would fire a request per keystroke. Cancel therefore has to
/// mean something, which is why the sheet edits a copy.
struct LogFilterSheet: View {
    @State private var draft: LogFilter
    @State private var valuesStore: LogFilterValuesStore
    @Environment(\.dismiss) private var dismiss

    private let onApply: (LogFilter) -> Void

    init(
        client: RenderClient,
        ownerID: String,
        resourceIDs: [String],
        filter: LogFilter,
        onApply: @escaping (LogFilter) -> Void
    ) {
        _draft = State(initialValue: filter)
        _valuesStore = State(
            initialValue: LogFilterValuesStore(client: client, ownerID: ownerID, resourceIDs: resourceIDs)
        )
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Message contains", text: $draft.text)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Request path", text: $draft.path)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Both accept wildcards and regular expressions, and are matched by Render rather than on this device.")
                }

                ForEach(LogFilter.Facet.allCases) { facet in
                    facetSection(facet)
                }
            }
            .navigationTitle("Filter Logs")
            .navigationBarTitleDisplayMode(.inline)
            .task { await valuesStore.load() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        dismiss()
                        onApply(draft)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear All", role: .destructive) { draft.reset() }
                        .disabled(draft.isEmpty)
                }
            }
        }
    }

    /// A facet with no known values and nothing selected is omitted entirely — an empty picker is
    /// worse than no picker, and which facets exist genuinely varies by service.
    @ViewBuilder
    private func facetSection(_ facet: LogFilter.Facet) -> some View {
        let options = valuesStore.options(for: facet, selected: draft[facet])
        if !options.isEmpty {
            Section(facet.title) {
                ForEach(options, id: \.self) { option in
                    Button {
                        toggle(option, in: facet)
                    } label: {
                        HStack {
                            Text(option)
                            Spacer()
                            if draft[facet].contains(option) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    // Otherwise every option renders in the accent color, which reads as a row full
                    // of links and leaves the checkmark as the only thing distinguishing selected
                    // from not.
                    .buttonStyle(.plain)
                }
            }
        } else if !valuesStore.hasLoaded {
            Section(facet.title) {
                HStack {
                    ProgressView()
                    Text("Loading values…")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func toggle(_ option: String, in facet: LogFilter.Facet) {
        var selected = draft[facet]
        if selected.contains(option) {
            selected.remove(option)
        } else {
            selected.insert(option)
        }
        draft[facet] = selected
    }
}
