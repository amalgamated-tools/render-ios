import RenderAPI
import SwiftUI

/// One datastore in a list: glyph, name, status chip, and a plan/region/version subtitle.
/// Shared by the Postgres and Key Value lists — both are `DatabaseStatus`-shaped rows, and the
/// asymmetries (a replica badge) fit in one optional.
struct DatastoreRow: View {
    let name: String
    let status: Components.Schemas.DatabaseStatus
    let systemImage: String
    let accent: Color
    /// e.g. "Basic 1gb · Oregon · Postgres 16".
    let detailLine: String
    /// "Replica" for a Postgres read replica; nil otherwise.
    var roleBadge: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.row) {
            GlyphTile(systemImage: systemImage, tint: accent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.tight) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)
                    if let roleBadge {
                        MiniBadge(title: roleBadge)
                    }
                }
                HStack(spacing: Theme.Spacing.tight) {
                    DatabaseStatusChip(status: status, isCompact: true)
                    Text(detailLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
