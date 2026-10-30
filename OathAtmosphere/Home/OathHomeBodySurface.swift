import SwiftUI

/// Both wallet summaries end their actions at the same inset, regardless of
/// whether the content above them is a portfolio change or an asset logo.
/// Minimum sizing still allows larger text and stacked actions to grow.
struct OathWalletSummaryLayout: Layout {
    let viewportHeight: CGFloat
    let bottomSafeAreaInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let measured = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        // Keep equal header heights and enough space for the balance group
        // to sit between the toolbar and actions, including at larger text sizes.
        let minimumHeight = min(360, max(280, (viewportHeight + bottomSafeAreaInset) * 0.4))
        return CGSize(width: proposal.width ?? measured.map(\.width).max() ?? 0,
                      // Reserve at least 44pt above the centered group, even
                      // with large text: a settled 28pt ring plus 8pt either
                      // side fits without moving the balance while refreshing.
                      height: max(minimumHeight, measured.reduce(0) { $0 + $1.height } + 44 * 2 + 40))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let childProposal = ProposedViewSize(width: bounds.width, height: nil)
        let actionsHeight = subviews[1].sizeThatFits(childProposal).height
        let actionsTop = bounds.maxY - 40 - actionsHeight
        // Center the whole balance group in the available space. Measuring the
        // actions also preserves centering when they stack for larger text.
        subviews[0].place(at: CGPoint(x: bounds.midX, y: (bounds.minY + actionsTop) / 2),
                          anchor: .center, proposal: childProposal)
        subviews[1].place(at: CGPoint(x: bounds.midX, y: bounds.maxY - 40),
                          anchor: .bottom, proposal: childProposal)
    }
}

/// A native stack with a background confined to its own body. In a List this
/// is one reusable cell; it must never paint a canvas over subsequent cells.
/// Home and asset details share the same compact section inset.
struct OathHeaderScrollContent<Header: View, Content: View>: View {
    let viewportHeight: CGFloat
    var fillsViewport = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: OathHomeBodySurface.clearance) {
            VStack(spacing: 0, content: header)
                .fixedSize(horizontal: false, vertical: true)
                .anchorPreference(key: OathHeaderBounds.self, value: .bounds) { $0 }
            VStack(spacing: 0, content: content)
                .padding(.top, OathHomeBodySurface.contentInset)
                .frame(maxWidth: .infinity)
                .frame(maxHeight: fillsViewport ? .infinity : nil, alignment: .top)
                .background { OathHomeBodySurface() }
        }
        // Accept the native cell's height throughout both growth and shrinkage.
        // With either bound omitted, List can center the old/new intrinsic
        // content during chart expansion, moving even the unchanged header.
        .frame(minHeight: fillsViewport ? max(0, viewportHeight) : 0, maxHeight: .infinity, alignment: .top)
    }
}

private struct OathHeaderBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// The artwork owns its contrast requirement; the enclosing screen passes it
/// to native bars without changing the appearance of the list or presented sheets.
private struct OathArtworkAtScrollEdge: PreferenceKey {
    // Unrelated children contribute the identity value, never overwrite a
    // measured list surface. Welcome has no scrolling surface and stays dark.
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value && nextValue() }
}

struct OathArtworkNavigationAppearance: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var artworkAtTop = true

    func body(content: Content) -> some View {
        // Resolve the navigation bar explicitly on both surfaces. Clearing the
        // preference leaves custom toolbar hosts to inherit their previous or
        // system appearance, which can differ from the app's selected theme.
        // This styles native chrome only, never the list or presented sheets.
        let navigationScheme: ColorScheme = artworkAtTop ? .dark : colorScheme
        if #available(iOS 27, *) {
            content
                .toolbarColorScheme(navigationScheme, for: .navigationBar)
                .toolbarColorScheme(artworkAtTop ? .dark : nil, for: .statusBar)
                .onPreferenceChange(OathArtworkAtScrollEdge.self) { artworkAtTop = $0 }
        } else {
            content
                .toolbarColorScheme(navigationScheme, for: .navigationBar)
                .onPreferenceChange(OathArtworkAtScrollEdge.self) { artworkAtTop = $0 }
        }
    }
}

/// Dark mode carries the animated colors through one continuous frosted panel.
/// Keep the material behind the entire list, rather than giving reusable rows
/// separate blur layers with visible seams. Light mode keeps its opaque canvas.
struct OathHeaderScrollBackground<Artwork: View>: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder let artwork: () -> Artwork

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(OathHeaderBounds.self) { bounds in
            GeometryReader { geometry in
                Color.clear.preference(key: OathArtworkAtScrollEdge.self,
                    value: bounds.map { geometry[$0].maxY + OathHomeBodySurface.clearance > 0 } ?? false)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .backgroundPreferenceValue(OathHeaderBounds.self) { bounds in
            GeometryReader { geometry in
                let top = bounds.map { geometry[$0].maxY + OathHomeBodySurface.clearance } ?? 0
                let bottom = top + (bounds == nil ? 0 : OathHomeBodySurface.cornerRadius)
                let frosted = colorScheme == .dark && !reduceTransparency
                Color(uiColor: OathSurfaceColors.groupedCanvas)
                    .overlay {
                        artwork()
                            .mask(alignment: .top) {
                                Rectangle().frame(height: frosted ? geometry.size.height : max(0, min(geometry.size.height, bottom)))
                            }
                    }
                    .overlay(alignment: .bottom) {
                        if frosted {
                            Rectangle()
                                .fill(.regularMaterial)
                                .overlay(Color.black.opacity(0.18))
                                .overlay {
                                    LinearGradient(colors: [.white.opacity(0.04), .clear, .black.opacity(0.12)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                                .mask(alignment: .bottom) {
                                    Rectangle().frame(height: max(0, min(geometry.size.height, geometry.size.height - top)))
                                }
                        }
                    }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The panel and following cells form one uninterrupted surface.
/// Its native background proposal is exactly the body size, including the
/// empty-state minimum height. Later asset rows own their own backgrounds.
/// Layout/scroll passes are ordinary presentation, not diagnostic failures.
private struct OathHomeBodySurface: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // Keep the canvas below the native glass actions' backdrop.
    nonisolated static let clearance: CGFloat = 8
    // The old width-dependent 96–112pt inset reserved room for a fade that no
    // longer exists. Section content now starts at the regular list margin.
    nonisolated static let contentInset: CGFloat = 20
    nonisolated static let cornerRadius: CGFloat = 0

    private let surface = Color(uiColor: OathSurfaceColors.groupedCanvas)

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: Self.cornerRadius, topTrailingRadius: Self.cornerRadius, style: .continuous)
            .fill(colorScheme == .dark && !reduceTransparency ? .clear : surface)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
