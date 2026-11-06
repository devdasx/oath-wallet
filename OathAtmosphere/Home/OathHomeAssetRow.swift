import SwiftUI

struct OathHomeAssetRow: View, Equatable {
    let chain: OathImportChain
    let presentation: OathHomeAssetPresentation
    let balancesHidden: Bool
    var showsSeparator = false
    var isSearchResult = false
    private var pendingCountText: String {
        presentation.holding.pendingTransactionCount.formatted(
            .number.grouping(.never).locale(strings.language.locale))
    }
    @ScaledMetric(relativeTo: .caption2) private var badgeSize = 18.0
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.layoutDirection) private var layoutDirection

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chain == rhs.chain && lhs.presentation == rhs.presentation &&
        lhs.balancesHidden == rhs.balancesHidden && lhs.showsSeparator == rhs.showsSeparator &&
        lhs.isSearchResult == rhs.isSearchResult
    }

    var body: some View {
        OathRefinedListRow(
            title: strings.invariant(isSearchResult ? presentation.holding.symbol : presentation.holding.name),
            subtitle: isSearchResult ? strings.invariant(presentation.holding.name) : priceDescription,
            value: presentation.fiat,
            primaryFontWeight: .medium,
            detail: strings.invariant(presentation.nativeSummary),
            showsSeparator: showsSeparator,
            concealsAmounts: balancesHidden,
            emphasizesBalanceSubtitle: !isSearchResult,
            titleBadgeAsset: isSearchResult || presentation.holding.reference != "native" ? chain.logoAsset : nil,
            assetNetworkName: isSearchResult ? strings.invariant(chain.name) : nil,
            showsAssetNetworkBadge: presentation.holding.reference != "native",
            customSubtitle: isSearchResult ? nil : AnyView(OathAssetUnitPrice(
                price: presentation.unitPrice)),
            emphasizesBalanceDetail: true
        ) { size in
            OathSendLogo(holding: presentation.holding, size: size, showsChainBadge: false)
                .overlay(alignment: .topTrailing) {
                    if presentation.holding.pendingTransactionCount > 0 {
                        Text(pendingCountText)
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: badgeSize, minHeight: badgeSize)
                            .background(.red, in: Capsule())
                            .offset(x: layoutDirection == .rightToLeft ? -5 : 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var priceDescription: String {
        presentation.unitPrice ?? strings.text(.assetPriceUnavailable)
    }

    private var accessibilityText: String {
        let pending = presentation.holding.pendingTransactionCount
        let pendingDescription = pending > 0 ? ", \(strings.text(.assetPending)): \(pendingCountText)" : ""
        let symbol = isSearchResult ? "\(presentation.holding.symbol), " : ""
        let price = isSearchResult ? "" : ", \(strings.text(.assetPriceLabel)): \(priceDescription)"
        let identity = "\(symbol)\(presentation.holding.name), \(chain.name)\(pendingDescription)\(price)"
        if balancesHidden { return "\(identity), \(strings.text(.balanceHidden))" }
        return "\(identity), \(presentation.fiat), \(presentation.nativeFull)"
    }
}

/// Public unit prices stay visible when wallet balances are concealed.
/// Missing market coverage is an expected display state, not a new app error.
struct OathAssetUnitPrice: View {
    let price: String?
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        if let price {
            // Inherit the row subtitle's secondary style, shared with native units.
            Text(verbatim: price)
                .accessibilityIdentifier("home.asset.unitPrice")
        } else {
            Label(strings.text(.assetPriceUnavailable), systemImage: "exclamationmark.circle")
                .anchorPreference(key: OathUntrackedPriceBounds.self, value: .bounds) { $0 }
                .accessibilityHidden(true)
        }
    }
}

private struct OathUntrackedPriceBounds: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

extension View {
    /// A sibling hit target over the label avoids nesting a button inside the
    /// asset navigation button. Remaining row taps still open asset details.
    func oathUntrackedPriceAction(_ action: @escaping () -> Void) -> some View {
        modifier(OathUntrackedPriceAction(action: action))
    }
}

private struct OathUntrackedPriceAction: ViewModifier {
    let action: () -> Void
    @Environment(\.oathLocalizer) private var strings
    func body(content: Content) -> some View {
        content.overlayPreferenceValue(OathUntrackedPriceBounds.self) { anchor in
            GeometryReader { geometry in
                if let anchor {
                    let bounds = geometry[anchor]
                    OathButton(action: action) {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(width: bounds.width, height: max(44, bounds.height))
                    .position(x: bounds.midX, y: bounds.midY)
                    .accessibilityLabel(strings.text(.assetPriceUnavailable))
                    .accessibilityIdentifier("home.asset.priceUntracked")
                }
            }
        }
    }
}

/// Match wallet/input trees: semantic leading indentation, rounded hairlines,
/// and decorative branches that never intercept the asset's tap target.
struct OathAssetTreeHeading: View {
    let chain: OathImportChain
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 52.0
    @Environment(\.oathLocalizer) private var strings

    var body: some View {
        HStack(spacing: 12) {
            OathNetworkLogo(asset: chain.logoAsset, size: iconSize).frame(width: iconColumnWidth)
                .accessibilityHidden(true)
            Text(strings.invariant(chain.name)).oathFont(.callout, weight: .semibold)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 13).frame(minHeight: 78)
        .accessibilityAddTraits(.isHeader)
    }
}

struct OathAssetTreeRow<Content: View>: View {
    let entry: OathHomeAssetTreeEntry?
    @ViewBuilder let content: () -> Content
    @ScaledMetric(relativeTo: .body) private var indentation = 28.0
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 52.0

    var body: some View {
        content()
            .padding(.leading, entry?.isChild == true ? indentation : 0)
            .overlay {
                if let entry {
                    OathAssetTreeBranch(isChild: entry.isChild, hasChildren: entry.hasChildren,
                        continues: entry.continues, indentation: indentation,
                        iconSize: iconSize, iconColumnWidth: iconColumnWidth)
                        .stroke(Color(uiColor: .separator), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

private struct OathAssetTreeBranch: Shape {
    let isChild: Bool
    let hasChildren: Bool
    let continues: Bool
    let indentation: CGFloat
    let iconSize: CGFloat
    let iconColumnWidth: CGFloat
    var layoutDirectionBehavior: LayoutDirectionBehavior { .mirrors }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = rect.minX + 20 + iconColumnWidth / 2
        if isChild {
            path.move(to: CGPoint(x: x, y: rect.minY))
            path.addLine(to: CGPoint(x: x, y: continues ? rect.maxY : rect.midY))
            path.move(to: CGPoint(x: x, y: rect.midY))
            path.addLine(to: CGPoint(x: x + indentation - iconSize / 2 - 4, y: rect.midY))
        }
        if hasChildren {
            path.move(to: CGPoint(x: x, y: rect.midY + iconSize / 2 + 4))
            path.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        return path
    }
}
