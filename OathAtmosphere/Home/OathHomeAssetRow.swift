import SwiftUI

struct OathHomeAssetRow: View, Equatable {
    let chain: OathImportChain
    let presentation: OathHomeAssetPresentation
    let balancesHidden: Bool
    var showsSeparator = false
    private var pendingCountText: String {
        presentation.holding.pendingTransactionCount.formatted(
            .number.grouping(.never).locale(strings.language.locale))
    }
    @ScaledMetric(relativeTo: .caption2) private var badgeSize = 18.0
    @Environment(\.oathLocalizer) private var strings

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chain == rhs.chain && lhs.presentation == rhs.presentation &&
        lhs.balancesHidden == rhs.balancesHidden && lhs.showsSeparator == rhs.showsSeparator
    }

    var body: some View {
        OathRefinedListRow(
            title: strings.invariant(presentation.holding.name),
            subtitle: strings.invariant(presentation.nativeSummary),
            value: presentation.fiat,
            showsSeparator: showsSeparator,
            concealsAmounts: balancesHidden,
            concealsSubtitle: balancesHidden,
            emphasizesBalanceSubtitle: true,
            titleBadgeAsset: presentation.holding.reference == "native" ? nil : chain.logoAsset
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
                            .offset(x: 5, y: -5)
                            .accessibilityHidden(true)
                    }
                }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let pending = presentation.holding.pendingTransactionCount
        let pendingDescription = pending > 0 ? ", \(strings.text(.assetPending)): \(pendingCountText)" : ""
        let identity = "\(presentation.holding.name), \(chain.name)\(pendingDescription)"
        if balancesHidden { return "\(identity), \(strings.text(.balanceHidden))" }
        return "\(identity), \(presentation.fiat), \(presentation.nativeFull)"
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
