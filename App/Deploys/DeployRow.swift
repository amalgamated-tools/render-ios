import RenderAPI
import SwiftUI

/// One deploy: status, what shipped, when, and how long it took.
///
/// Used both in the deploy history list and — with `showsStatus: false` — under the detail screen's
/// status chip, where repeating the status would be noise.
struct DeployRow: View {
    let deploy: DeploySummary
    var showsStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsStatus, let status = deploy.status {
                DeployStatusChip(status: status, isCompact: true)
            }
            Text(subject)
                .font(.subheadline)
                .lineLimit(2)
            Text(metadata)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The commit subject is the most useful identifier; fall back to the image ref for
    /// image-backed deploys, and to the deploy ID when neither exists.
    private var subject: String {
        if let commitSubject = deploy.commitSubject, !commitSubject.isEmpty { return commitSubject }
        if let imageRef = deploy.imageRef { return imageRef }
        return deploy.id
    }

    private var metadata: String {
        var parts: [String] = []
        if let shortCommitID = deploy.shortCommitID {
            parts.append(shortCommitID)
        }
        if let trigger = deploy.trigger {
            parts.append(trigger.displayName)
        }
        if let timestamp = deploy.timestamp {
            parts.append(timestamp.formatted(.relative(presentation: .named)))
        }
        if let duration = deploy.duration {
            parts.append(Self.durationFormat(duration))
        }
        return parts.joined(separator: " · ")
    }

    /// Deploys run from seconds to tens of minutes; "4m 12s" reads faster than either unit alone.
    static func durationFormat(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}
