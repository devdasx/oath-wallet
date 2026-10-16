import SwiftUI

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
    var detail: String? = nil
    var showsSeparator = false
    @ViewBuilder let icon: (CGFloat) -> Icon

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = 40.0
    @ScaledMetric(relativeTo: .body) private var iconColumnWidth = 42.0

    var body: some View {
        HStack(spacing: 12) {
            icon(iconSize)
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)
            if typeSize.isAccessibilitySize {
                stackedLabels
            } else {
                HStack(spacing: 12) {
                    identity.frame(maxWidth: .infinity, alignment: .leading)
                    amounts(alignment: .trailing).layoutPriority(1)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.85)
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

    private var identity: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: title)
                .oathFont(.callout, weight: .semibold)
                .foregroundStyle(.primary)
                .truncationMode(.tail)
            Text(verbatim: subtitle)
                .oathFont(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func amounts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(verbatim: value)
                .oathFont(.body, weight: .semibold)
                .foregroundStyle(.primary)
            if let detail {
                Text(verbatim: detail)
                    .oathFont(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
