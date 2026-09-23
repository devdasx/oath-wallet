import SwiftUI

/// Wraps the inline controls of a recovery-phrase editor at available width.
/// The editor supplies LTR direction so mnemonic positions never mirror.
struct RecoveryPhraseWordLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 600, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = positions(width: bounds.width, subviews: subviews)
        for (index, item) in layout.items.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func positions(width: CGFloat, subviews: Subviews) -> (size: CGSize, items: [CGRect]) {
        let width = max(width, 1)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var items: [CGRect] = []
        var rowStart = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let itemWidth = min(ceil(ideal.width), width)
            // Measure at the exact width used for placement. In particular,
            // a large-text word may need a taller pill when it fills the row.
            let size = subview.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            if x > 0 && x + itemWidth > width {
                for index in rowStart..<items.count {
                    items[index].origin.y += (rowHeight - items[index].height) / 2
                }
                rowStart = items.count
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        for index in rowStart..<items.count {
            items[index].origin.y += (rowHeight - items[index].height) / 2
        }
        return (CGSize(width: width, height: y + rowHeight), items)
    }
}
