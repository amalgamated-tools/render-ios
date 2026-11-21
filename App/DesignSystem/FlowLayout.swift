import SwiftUI

/// Lays out its children left to right at their natural width, starting a new line when the next
/// one doesn't fit. A child wider than the whole line gets the full width and wraps its own text.
///
/// For rows of chips. `ViewThatFits` with an HStack and a VStack fallback looked like the same thing
/// but isn't: an HStack of text "fits" any width by wrapping each chip mid-word ("Vir-ginia"), so
/// the fallback was never chosen at large Dynamic Type.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, in: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, in: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, in maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            // Measured against the full line, not `.unspecified`: a chip asked for its ideal size
            // with no width came back tall, narrow and blank inside a List row. Offered the whole
            // line, a chip that fits on one line still reports its natural width, and one wider
            // than the line takes all of it and wraps its own text.
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let needed = current.items.isEmpty ? size.width : current.width + spacing + size.width
            if !current.items.isEmpty && needed > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.items.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}
