import SwiftUI
import OathDatabase

/// Shared by Send and Receive: one layout, balance formatter and token identity.
struct OathAssetSelectionRow: View {
    let holding: Holding
    let currency: String
    var showsNetwork = false
    @Environment(\.oathLocalizer) private var strings
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var iconSize = 38.0
    private var native: String {
        guard let raw = holding.amountAtomic,
              let units = OathSendAmount.units(raw, decimals: holding.decimals) else { return strings.text(.sendBalanceUnknown) }
        return strings.invariant(units + " " + holding.symbol)
    }

    private var nativeSummary: String {
        guard let amount = holding.nativeDisplayValue else { return strings.text(.sendBalanceUnknown) }
        return strings.invariant(OathAssetAmountFormat(locale: strings.language.locale)
            .nativeSummary(amount, ticker: holding.symbol))
    }

    private var fiat: String {
        holding.fiatDisplayValue.map { $0.formatted(.currency(code: currency).locale(strings.language.locale)) }
            ?? strings.text(.assetPriceUnavailable)
    }

    var body: some View {
        OathListRow {
            OathSendLogo(holding: holding, size: iconSize)
        } content: {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    title
                    balances(alignment: .leading)
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                title.frame(maxWidth: .infinity, alignment: .leading)
                balances(alignment: .trailing).layoutPriority(1)
            }
        } accessory: {
            EmptyView()
        }
        .foregroundStyle(.primary)
        .accessibilityLabel([holding.name, showsNetwork ? OathImportChain(rawValue: holding.networkID)?.name : nil, fiat, native]
            .compactMap { $0 }.joined(separator: ", "))
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(strings.invariant(holding.name)).oathFont(.body, weight: .semibold)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if showsNetwork, let chain = OathImportChain(rawValue: holding.networkID), chain.name != holding.name {
                Text(strings.invariant(chain.name)).oathFont(.footnote).foregroundStyle(.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func balances(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(fiat).oathFont(.body, weight: .medium)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.75)
            Text(nativeSummary).oathFont(.footnote).foregroundStyle(.secondary)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1).minimumScaleFactor(0.75)
        }
        .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
    }
}
