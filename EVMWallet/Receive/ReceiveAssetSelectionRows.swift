import SwiftUI

struct ReceiveVariantSelection: Identifiable, Sendable {
    let token: ReceiveToken
    let variant: ReceiveTokenVariant

    var id: String {
        AssetIdentityKey.canonical(variant.assetIdentity)
    }
}

struct ReceiveVariantRow: View {
    let selection: ReceiveVariantSelection
    private let holding: ReceiveHolding
    let isBalanceHidden: Bool
    let supplementaryText: String?

    init(
        selection: ReceiveVariantSelection,
        walletAssets: [WalletAsset],
        isBalanceHidden: Bool,
        supplementaryText: String? = nil
    ) {
        self.selection = selection
        self.isBalanceHidden = isBalanceHidden
        self.supplementaryText = supplementaryText
        holding = ReceiveHoldingLookup.holding(
            for: selection.variant,
            in: walletAssets
        )
    }

    init(
        selection: ReceiveVariantSelection,
        holdingAsset: WalletAsset?,
        isBalanceHidden: Bool,
        supplementaryText: String? = nil
    ) {
        self.selection = selection
        self.isBalanceHidden = isBalanceHidden
        self.supplementaryText = supplementaryText
        holding = ReceiveHoldingLookup.holding(for: holdingAsset)
    }

    var body: some View {
        UnifiedAssetSelectionRow(
            name: selection.token.name,
            symbol: selection.token.symbol,
            logoSource: selection.variant.logoSource,
            networkLogoSource: selection.variant.network.map {
                .network(blockchain: $0.blockchain)
            },
            familyLogoSource: selection.variant.familyLogoSource,
            balance: holding.balance,
            fiatValue: holding.fiatValue,
            isBalanceHidden: isBalanceHidden,
            logoDiagnosticIdentity: selection.variant.assetIdentity,
            supplementaryText: supplementaryText
        )
    }
}

private struct ReceiveHolding: Sendable {
    let balance: Decimal
    let fiatValue: Decimal
}

private enum ReceiveHoldingLookup {
    static func holding(for asset: WalletAsset?) -> ReceiveHolding {
        guard let asset else {
            return ReceiveHolding(balance: 0, fiatValue: 0)
        }
        return ReceiveHolding(
            balance: asset.balance,
            fiatValue: asset.fiatValue
        )
    }

    static func holding(
        for variant: ReceiveTokenVariant,
        in walletAssets: [WalletAsset]
    ) -> ReceiveHolding {
        holding(
            for: walletAssets.first(where: {
                $0.id.caseInsensitiveCompare(variant.assetIdentity)
                    == .orderedSame
            })
        )
    }

    static func holding(
        for token: ReceiveToken,
        in walletAssets: [WalletAsset]
    ) -> ReceiveHolding {
        token.variants.reduce(
            ReceiveHolding(balance: 0, fiatValue: 0)
        ) { partial, variant in
            let next = holding(for: variant, in: walletAssets)
            return ReceiveHolding(
                balance: partial.balance + next.balance,
                fiatValue: partial.fiatValue + next.fiatValue
            )
        }
    }
}

struct ReceiveTokenRow: View {
    let token: ReceiveToken
    let walletAssets: [WalletAsset]
    var selectedNetworkID: String? = nil
    let isBalanceHidden: Bool

    var body: some View {
        let selectedVariant = selectedNetworkID.flatMap { networkID in
            token.variants.first {
                $0.networkID == networkID
            }
        }
        let displayedVariant = selectedVariant ?? token.variants.first
        let holding = if let selectedVariant {
            ReceiveHoldingLookup.holding(
                for: selectedVariant,
                in: walletAssets
            )
        } else {
            ReceiveHoldingLookup.holding(
                for: token,
                in: walletAssets
            )
        }

        UnifiedAssetSelectionRow(
            name: token.name,
            symbol: token.symbol,
            logoSource: displayedVariant?.logoSource
                ?? .unavailable,
            networkLogoSource: displayedVariant?.network.map {
                .network(blockchain: $0.blockchain)
            },
            familyLogoSource: displayedVariant?.familyLogoSource,
            balance: holding.balance,
            fiatValue: holding.fiatValue,
            isBalanceHidden: isBalanceHidden,
            logoDiagnosticIdentity: displayedVariant?.assetIdentity
        )
    }
}

struct UnifiedAssetSelectionRow: View {
    let name: String
    let symbol: String
    let logoSource: AssetLogoSource
    var networkLogoSource: AssetLogoSource? = nil
    var familyLogoSource: AssetLogoSource? = nil
    let balance: Decimal?
    let fiatValue: Decimal?
    let isBalanceHidden: Bool
    var logoDiagnosticIdentity: String? = nil
    var supplementaryText: String? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.walletCurrencyContext) private var currencyContext

    var body: some View {
        let assetAmountText = balance.map(formattedAssetAmount)
        let fiatText = EnglishNumbers.currency(fiatValue ?? 0, using: currencyContext)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    identity(assetAmountText: assetAmountText)
                    values(fiatText: fiatText)
                }
            } else {
                HStack(spacing: 14) {
                    identity(assetAmountText: assetAmountText)
                    Spacer(minLength: 12)
                    values(fiatText: fiatText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func identity(assetAmountText: String?) -> some View {
        HStack(spacing: 14) {
            WalletAssetLogoBadges(
                logoSource: logoSource,
                networkLogoSource: networkLogoSource,
                familyLogoSource: familyLogoSource,
                size: 44,
                animatesChanges: false,
                diagnosticAssetIdentity:
                    logoDiagnosticIdentity ?? symbol
            )

            VStack(alignment: .leading, spacing: 4) {
                if let assetAmountText {
                    Text(name)
                        .font(WalletTypography.listRowTitle)
                        .foregroundStyle(WalletTheme.primaryLabel)
                        .lineLimit(2)

                    WalletPrivacyReplacement(
                        isHidden: isBalanceHidden,
                        alignment: .leading
                    ) {
                        Text(assetAmountText)
                    }
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    supplementaryIdentityText
                } else {
                    Text(symbol)
                        .font(WalletTypography.listRowTitle)
                        .foregroundStyle(WalletTheme.primaryLabel)
                        .lineLimit(2)

                    Text(name)
                        .font(.subheadline)
                        .foregroundStyle(WalletTheme.secondaryLabel)
                    supplementaryIdentityText
                }
            }
        }
    }

    @ViewBuilder
    private var supplementaryIdentityText: some View {
        if let supplementaryText, !supplementaryText.isEmpty {
            Text(verbatim: supplementaryText)
                .font(.caption)
                .foregroundStyle(WalletTheme.secondaryLabel)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func values(fiatText: String?) -> some View {
        if let fiatText {
            WalletPrivacyReplacement(
                isHidden: isBalanceHidden,
                alignment: dynamicTypeSize.isAccessibilitySize
                    ? .leading
                    : .trailing
            ) {
                Text(fiatText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .multilineTextAlignment(
                        dynamicTypeSize.isAccessibilitySize
                            ? .leading
                            : .trailing
                    )
            }
        }
    }

    private func formattedAssetAmount(_ balance: Decimal) -> String {
        EnglishNumbers.localized(
            "wallet.format.asset_amount",
            EnglishNumbers.decimal(balance),
            symbol
        )
    }
}
