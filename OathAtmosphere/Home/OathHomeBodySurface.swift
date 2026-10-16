import SwiftUI

/// One scroll subtree with a rounded canvas below the complete colored header.
/// Home and asset details share the same compact section inset.
struct OathHeaderScrollContent<Header: View, Content: View>: View {
    let viewportHeight: CGFloat
    var fillsViewport = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        OathHeaderScrollLayout(viewportHeight: viewportHeight, fillsViewport: fillsViewport) {
            OathHomeBodySurface()
            VStack(spacing: 0, content: header)
            VStack(spacing: 0, content: content)
        }
    }
}

/// Measures the real foreground sizes in the same layout pass. No deferred
/// geometry-to-state writes, fixed header heights, or scroll-dependent resizing
/// of the artwork. Extra background coverage never adds to the scroll extent.
private struct OathHeaderScrollLayout: Layout {
    let viewportHeight: CGFloat
    let fillsViewport: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let dimensions = measure(proposal: proposal, subviews: subviews)
        return CGSize(width: dimensions.width,
                      height: dimensions.header + dimensions.gap + dimensions.content)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let dimensions = measure(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        let surfaceHeight = dimensions.inset + dimensions.content + max(0, viewportHeight)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + dimensions.header + OathHomeBodySurface.clearance),
            anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: surfaceHeight))
        subviews[1].place(at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: dimensions.header))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.minY + dimensions.header + dimensions.gap),
            anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: dimensions.content))
    }

    private func measure(proposal: ProposedViewSize, subviews: Subviews)
        -> (width: CGFloat, header: CGFloat, content: CGFloat, inset: CGFloat, gap: CGFloat) {
        let width = max(1, proposal.width ?? max(subviews[1].sizeThatFits(.unspecified).width,
                                               subviews[2].sizeThatFits(.unspecified).width))
        let childProposal = ProposedViewSize(width: width, height: nil)
        let header = subviews[1].sizeThatFits(childProposal).height
        let inset = OathHomeBodySurface.contentInset
        let naturalContent = subviews[2].sizeThatFits(childProposal).height
        let content = fillsViewport ? max(naturalContent, viewportHeight - header - inset - OathHomeBodySurface.clearance) : naturalContent
        return (width, header, content, inset, inset + OathHomeBodySurface.clearance)
    }
}

/// Only the panel casts a small shadow; foreground rows and controls do not.
/// Extra coverage keeps overscroll and short lists opaque below the top corners.
private struct OathHomeBodySurface: View {
    // Keep the canvas below the native glass actions' backdrop.
    nonisolated static let clearance: CGFloat = 8
    // The old width-dependent 96–112pt inset reserved room for a fade that no
    // longer exists. Section content now starts at the regular list margin.
    nonisolated static let contentInset: CGFloat = 20

    private let surface = Color(uiColor: OathSurfaceColors.groupedCanvas)

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
            .fill(surface)
            .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: -2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
