import RenderAPI
import SwiftUI

/// A service's running instances and outbound IPs — mostly so "what IP do I allowlist?" can be
/// answered, and copied, from a phone.
struct ServiceNetworkView: View {
    @State private var store: ServiceNetworkStore

    init(client: RenderClient, serviceID: String) {
        _store = State(initialValue: ServiceNetworkStore(client: client, serviceID: serviceID))
    }

    var body: some View {
        List {
            outboundSection
            instancesSection
        }
        .navigationTitle("Instances & IPs")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load() }
        .task { await store.load() }
    }

    @ViewBuilder
    private var outboundSection: some View {
        Section {
            if let ips = store.outboundIPs {
                if let message = store.outboundIPsError {
                    errorLabel(message)
                }
                ForEach(ips.ips, id: \.self) { ip in
                    HStack {
                        Text(ip)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button("Copy", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = ip
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                if ips.ips.count > 1 {
                    Button("Copy All", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = ips.ips.joined(separator: "\n")
                    }
                }
            } else if let message = store.outboundIPsError {
                errorLabel(message)
            } else if store.isLoading {
                ProgressView()
            }
        } header: {
            Text("Outbound IPs")
        } footer: {
            if let ips = store.outboundIPs {
                if ips.isDedicated {
                    Text("A dedicated IP set\(ips.dedicatedSetID.map { " (\($0))" } ?? ""). Other services in this workspace or its selected environments can share these addresses. Allowlisting them also admits those services.")
                } else {
                    // Shared IPs are used by every service in the region, so allowlisting them admits
                    // more than this service — worth saying where the allowlisting happens.
                    Text("Shared with other Render services in this region. Allowlisting them also admits those services.")
                }
            }
        }
    }

    @ViewBuilder
    private var instancesSection: some View {
        Section {
            if let message = store.instancesError {
                errorLabel(message)
            }
            ForEach(store.instances) { instance in
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.id)
                        .font(.system(.subheadline, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("Started \(instance.createdAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if store.hasLoadedInstances, store.instances.isEmpty {
                Text("No running instances.")
                    .foregroundStyle(.secondary)
            } else if !store.hasLoadedInstances, store.instancesError == nil, store.isLoading {
                ProgressView()
            }
        } header: {
            Text(store.instances.isEmpty ? "Instances" : "Instances (\(store.instances.count))")
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.orange)
    }
}
