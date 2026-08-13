import SwiftUI

/// The "we couldn't load this" state, in one place.
///
/// This exact block — a triangle label, the store's message, a Retry button — was copy-pasted into
/// a dozen files, which is how the wording had already started to diverge. Behaviour is unchanged;
/// only the duplication is gone.
struct ErrorStateView: View {
    /// e.g. "services", "deploys". Phrased as the object of "Couldn't load …" so call sites can't
    /// drift into three different sentence shapes.
    let subject: String
    let message: String
    let retry: () async -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn't load \(subject)", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry") { Task { await retry() } }
        }
    }
}

/// A ghost list shown while the first page loads.
///
/// A centred spinner on a blank screen tells you the app is busy. A skeleton tells you what is
/// about to arrive and roughly how much of it, and the rows don't jump when the real ones land,
/// because they are the same rows with placeholder content.
struct SkeletonList: View {
    var rows = 6

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { index in
                SkeletonRow()
                // Fade the tail out rather than ending on a hard edge — the list continues past
                // the fold and pretending otherwise reads as "this is all there is".
                    .opacity(1 - Double(index) / Double(rows) * 0.7)
                Divider().padding(.leading, Theme.Glyph.size + Theme.Spacing.row * 2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .redacted(reason: .placeholder)
        // Placeholder shapes are not information, and VoiceOver reading six rows of nothing is
        // worse than silence plus the announcement the real content makes when it arrives.
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// One ghost row, shaped like ``ServiceRow`` and ``DatastoreRow``: tile, title, subtitle.
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            RoundedRectangle(cornerRadius: Theme.Glyph.radius, style: .continuous)
                .fill(.quaternary)
                .frame(width: Theme.Glyph.size, height: Theme.Glyph.size)

            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.quaternary).frame(width: 150, height: 13)
                Capsule().fill(.quaternary).frame(width: 220, height: 11)
            }
            Spacer()
        }
        .padding(.vertical, Theme.Spacing.row)
    }
}
