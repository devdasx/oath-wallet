import SwiftUI
import OathTokenImages

/// Use display pixels, rather than points, for every app-owned separator.
enum OathHairlineMetrics {
    static func thickness(displayScale: CGFloat) -> CGFloat { 2 / max(displayScale, 1) }
}

struct OathHairline: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(height: OathHairlineMetrics.thickness(displayScale: displayScale))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// One row system for portfolio assets and transaction history. Callers supply
/// data and artwork; spacing, typography and accessibility layout stay shared.
struct OathRefinedListRow<Icon: View>: View {
    let title: String
    let subtitle: String
    let value: String
    var primaryFontWeight: Font.Weight = .semibold
    var detail: String? = nil
    var showsSeparator = false
    var concealsAmounts = false
    var concealsSubtitle = false
    var emphasizesBalanceSubtitle = false
    var titleBadgeAsset: String? = nil
    // Asset pickers/search show symbol + network above the full asset name,
    // with both balances in the trailing column. History keeps its own layout.
    var assetNetworkName: String? = nil
    // Rich transaction titles reuse the same row metrics and amount column.
    var customTitle: AnyView? = nil
    @ViewBuilder let icon: (CGFloat) -> Icon

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0
    // Includes the chain badge's right-edge overhang at every Dynamic Type size.
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 52.0
    @ScaledMetric(relativeTo: .subheadline) private var balanceSubtitleSize = 14.5
    @ScaledMetric(relativeTo: .callout) private var titleBadgeSize = 18.0

    var body: some View {
        HStack(spacing: 12) {
            icon(iconSize)
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                stackedLabels
            } else if assetNetworkName != nil {
                // Keep the full network identity readable when long names or
                // balances need more room than the two-column arrangement.
                ViewThatFits(in: .horizontal) {
                    columnLabels
                    stackedLabels
                }
            } else if detail != nil {
                transactionLabels
            } else {
                columnLabels
            }
        }
        .padding(.vertical, 13)
        .frame(minHeight: 78)
        .padding(.horizontal, 20)
        .overlay(alignment: .top) {
            if showsSeparator {
                OathHairline()
                    .padding(.leading, 20 + iconColumnWidth + 12)
                    .padding(.trailing, 20)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var columnLabels: some View {
        HStack(alignment: assetNetworkName == nil ? .center : .top, spacing: 12) {
            identity.frame(maxWidth: .infinity, alignment: .leading)
            amounts(alignment: .trailing).layoutPriority(1)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .minimumScaleFactor(0.85)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            titleLabel
            Text(verbatim: subtitle)
                .oathFont(.caption, weight: emphasizesBalanceSubtitle ? .medium : .regular,
                          size: emphasizesBalanceSubtitle ? balanceSubtitleSize : nil)
                .foregroundStyle(.secondary)
                .oathBalanceConcealed(concealsSubtitle)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var titleLabel: some View {
        HStack(spacing: 6) {
            if assetNetworkName == nil, let titleBadgeAsset {
                OathNetworkLogo(asset: titleBadgeAsset, size: titleBadgeSize)
                    .fixedSize()
                    .accessibilityHidden(true)
            }
            Group {
                if let customTitle { customTitle }
                else { Text(verbatim: title) }
            }
            .oathFont(.callout, weight: primaryFontWeight)
            .foregroundStyle(.primary)
            .truncationMode(.tail)
            if let assetNetworkName {
                HStack(spacing: 4) {
                    if let titleBadgeAsset {
                        OathNetworkLogo(asset: titleBadgeAsset, size: titleBadgeSize)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                    Text(verbatim: assetNetworkName)
                        .oathFont(.caption2, weight: .medium)
                        .foregroundStyle(.secondary)
                        .truncationMode(.tail)
                }
                .padding(.leading, titleBadgeAsset == nil ? 5 : 3)
                .padding(.trailing, 5)
                .padding(.vertical, 3)
                .background(Color(uiColor: OathSurfaceColors.networkBadge), in: networkBadgeShape)
            }
        }
    }

    private var networkBadgeShape: UnevenRoundedRectangle {
        let pillRadius = (titleBadgeSize + 6) / 2
        // Match the logo's continuous corners plus its equal three-point inset.
        // Semantic leading corners follow the logo in both LTR and RTL layouts.
        let logoRadius = titleBadgeAsset == nil ? pillRadius
            : titleBadgeSize * TokenArtworkStyle.cornerRadiusFraction + 3
        return UnevenRoundedRectangle(topLeadingRadius: logoRadius,
                                      bottomLeadingRadius: logoRadius,
                                      bottomTrailingRadius: pillRadius,
                                      topTrailingRadius: pillRadius,
                                      style: .continuous)
    }

    // Size each line independently: an exact token amount can be much longer
    // than its fiat value and must never steal space from the transaction title.
    private var transactionLabels: some View {
        VStack(spacing: 5) {
            HStack(spacing: 12) {
                titleLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: value)
                    .oathFont(.body, weight: primaryFontWeight)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                    .oathBalanceConcealed(concealsAmounts)
                    // Reserve the intrinsic amount width before offering the
                    // remaining space to the expanding transaction title.
                    .layoutPriority(1)
            }
            HStack(spacing: 12) {
                Text(verbatim: subtitle)
                    .oathFont(.caption)
                    .foregroundStyle(.secondary)
                    .oathBalanceConcealed(concealsSubtitle)
                    .fixedSize()
                Spacer(minLength: 0)
                if let detail {
                    Text(verbatim: detail)
                        .oathFont(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .truncationMode(.middle)
                        .oathBalanceConcealed(concealsAmounts)
                }
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }

    private func amounts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(verbatim: value)
                .oathFont(.body, weight: primaryFontWeight)
                .foregroundStyle(.primary)
            if let detail {
                Text(verbatim: detail)
                    .oathFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .oathBalanceConcealed(concealsAmounts)
        .monospacedDigit()
        .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stackedLabels: some View {
        VStack(alignment: .leading, spacing: 8) {
            identity
            amounts(alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OathRefinedTransactionIcon: View {
    let systemName: String
    let size: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(Color(uiColor: OathSurfaceColors.field), in: Circle())
    }
}

/// Conceal the existing value without changing its measured size or replacing it
/// with placeholder text. This is the user-selected balance visibility setting,
/// independent of the app's lock/background privacy protection.
private struct OathBalanceConcealment: ViewModifier {
    let hidden: Bool
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.oathLocalizer) private var strings
    @ScaledMetric(relativeTo: .body) private var blurScale = 1.0

    func body(content: Content) -> some View {
        content
            .blur(radius: hidden ? radius * blurScale : 0)
            .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: hidden)
            // Blurring pixels alone must never reveal the amount to VoiceOver.
            .accessibilityRepresentation {
                if hidden { Text(strings.text(.balanceHidden)) }
                else { content }
            }
    }
}

extension View {
    func oathBalanceConcealed(_ hidden: Bool, radius: CGFloat = 10) -> some View {
        modifier(OathBalanceConcealment(hidden: hidden, radius: radius))
    }
}
