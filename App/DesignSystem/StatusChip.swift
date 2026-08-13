import SwiftUI

/// The shared geometry behind every status pill.
///
/// ``DeployStatusChip`` and ``DatabaseStatusChip`` had drifted into being byte-for-byte identical
/// views over two different enums. Both are now thin wrappers over this: keeping the layout in one
/// place is what stops them drifting *apart* again, which is the failure mode that actually shows
/// up in a screenshot.
struct StatusChip: View {
    let title: String
    let systemImage: String
    let tint: Color
    var isCompact = false
    /// Pulses the glyph. Set while the thing being described is still moving — a deploy building,
    /// a database restarting — so a screen you're watching says so without a second spinner.
    var isActive = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .symbolEffect(.pulse, isActive: isActive)
        }
        .font(isCompact ? .caption.weight(.medium) : .subheadline.weight(.medium))
        .foregroundStyle(tint)
        .padding(.horizontal, Theme.Chip.horizontalPadding)
        .padding(.vertical, Theme.Chip.verticalPadding)
        .background(tint.opacity(Theme.Chip.fillOpacity(for: colorScheme)), in: Capsule())
    }
}

/// A neutral pill for facts rather than health — region, plan, instance count. Same geometry as a
/// status chip so a row of the two lines up, but it borrows the surrounding text colour instead of
/// claiming a semantic tint of its own.
struct FactChip: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if let systemImage {
                Image(systemName: systemImage)
            }
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Chip.horizontalPadding)
        .padding(.vertical, Theme.Chip.verticalPadding)
        .background(.quaternary, in: Capsule())
    }
}

/// The smallest badge: a word sitting next to a row's title, qualifying it. "Suspended" on a
/// service, "Replica" on a Postgres instance. Smaller than a ``StatusChip`` because it rides
/// alongside a headline rather than standing on its own line.
struct MiniBadge: View {
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Chip.horizontalPadding - 2)
            .padding(.vertical, Theme.Chip.verticalPadding - 1)
            .background(tint.opacity(Theme.Glyph.fillOpacity), in: Capsule())
    }
}

/// The tinted rounded-square tile behind a service-type or datastore glyph in a list row.
struct GlyphTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = Theme.Glyph.size

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.45))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(Theme.Glyph.fillOpacity),
                in: RoundedRectangle(cornerRadius: Theme.Glyph.radius, style: .continuous)
            )
    }
}
