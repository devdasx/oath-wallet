import SwiftUI

/// Pure layout arithmetic also exercised by host tests. Overflow grows the
/// scroll content instead of placing it behind a header or below the viewport.
struct OathEmptyStateGeometry {
    let height: CGFloat
    let contentY: CGFloat
    let footerY: CGFloat

    init(viewport: CGFloat, header: CGFloat, content: CGFloat, footer: CGFloat = 0, centersContent: Bool = true) {
        let header = max(0, header)
        let content = max(0, content)
        let footer = max(0, footer)
        height = centersContent ? max(max(0, viewport), header + content + footer) : header + content + footer
        contentY = header + (height - header - content - footer) / 2
        footerY = height - footer
    }
}

struct OathEmptyStateLayout: Layout {
    var minimumHeight: CGFloat = 0
    var centersContent = true

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(proposal, subviews)
        return CGSize(width: sizes.width, height: sizes.geometry.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: sizes.header))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes.geometry.contentY), anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: sizes.content))
        if subviews.count > 2 {
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + sizes.geometry.footerY), anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: sizes.footer))
        }
    }

    private func measure(_ proposal: ProposedViewSize, _ subviews: Subviews)
        -> (width: CGFloat, header: CGFloat, content: CGFloat, footer: CGFloat, geometry: OathEmptyStateGeometry) {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let child = ProposedViewSize(width: width, height: nil)
        let header = subviews[0].sizeThatFits(child).height
        let content = subviews[1].sizeThatFits(child).height
        let footer = subviews.count > 2 ? subviews[2].sizeThatFits(child).height : 0
        let geometry = OathEmptyStateGeometry(viewport: max(minimumHeight, proposal.height ?? 0),
                                             header: header, content: content, footer: footer, centersContent: centersContent)
        return (width, header, content, footer, geometry)
    }
}
