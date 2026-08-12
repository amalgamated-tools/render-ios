import RenderAPI
import SwiftUI

/// One service in the list: type glyph, name, a suspended badge, and the repo/branch subtitle.
struct ServiceRow: View {
    let service: ServiceSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: service.type.systemImage)
                .font(.title3)
                .foregroundStyle(service.type.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(service.name)
                        .font(.headline)
                        .lineLimit(1)
                    if service.isSuspended {
                        Text("Suspended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let repo = service.repo, let short = repoName(from: repo) {
            if let branch = service.branch { return "\(short) · \(branch)" }
            return short
        }
        return service.type.displayName
    }

    /// `https://github.com/acme/api` → `acme/api`.
    private func repoName(from repo: String) -> String? {
        guard let url = URL(string: repo) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard !parts.isEmpty else { return nil }
        return parts.suffix(2).joined(separator: "/")
    }
}
