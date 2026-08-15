import RenderAPI
import SwiftUI

/// One service in the list: type glyph, name, a suspended badge, and the repo/branch subtitle.
struct ServiceRow: View {
    let service: ServiceSummary
    /// Watching is otherwise invisible from the list, which is where you'd go to check what you set
    /// up — and an alerting feature you can't audit is one you stop trusting.
    var isWatched = false

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            GlyphTile(systemImage: service.type.systemImage, tint: service.type.accent)
                .accessibilityLabel(service.type.displayName)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(service.name)
                        .font(.headline)
                        .lineLimit(1)
                    if service.isSuspended {
                        MiniBadge(title: "Suspended")
                    }
                    if isWatched {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Watched for failures")
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
