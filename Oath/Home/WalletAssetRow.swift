import SwiftUI

extension WalletAsset {
    var listDisplayBalanceText: String {
        ExactDecimalText.rounded(displayBalanceText, maximumFractionDigits: 12)
            ?? EnglishNumbers.decimal(balance, maximumFractionDigits: 12)
    }
}

struct WalletAssetRow: View {
    let asset: WalletAsset
    let isBalanceHidden: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.walletCurrencyContext) private var currencyContext

    init(
        asset: WalletAsset,
        isBalanceHidden: Bool
    ) {
        self.asset = asset
        self.isBalanceHidden = isBalanceHidden
    }

    var body: some View {
        let formattedAmount = EnglishNumbers.localized(
            "wallet.format.asset_amount",
            asset.listDisplayBalanceText,
            asset.symbol
        )
        let formattedFiatValue = asset.formattedWalletFiat(using: currencyContext)

        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    identity(formattedAmount: formattedAmount)
                    values(formattedFiatValue: formattedFiatValue)
                }
            } else {
                HStack(spacing: 14) {
                    identity(formattedAmount: formattedAmount)
                    Spacer(minLength: 12)
                    values(formattedFiatValue: formattedFiatValue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityLabel(
                formattedAmount: formattedAmount,
                formattedFiatValue: formattedFiatValue
            )
        )
    }

    private func identity(
        formattedAmount: String
    ) -> some View {
        HStack(spacing: 14) {
            WalletAssetLogoWithNetworkBadge(asset: asset)

            VStack(alignment: .leading, spacing: 4) {
                Text(asset.name)
                    .font(WalletTypography.listRowTitle)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(2)

                WalletPrivacyReplacement(
                    isHidden: isBalanceHidden,
                    alignment: .leading
                ) {
                    Text(formattedAmount)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)
            }
        }
    }

    private func values(
        formattedFiatValue: String
    ) -> some View {
        WalletPrivacyReplacement(
            isHidden: isBalanceHidden,
            alignment: dynamicTypeSize.isAccessibilitySize
                ? .leading
                : .trailing
        ) {
            Text(formattedFiatValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(WalletTheme.primaryLabel)
                .multilineTextAlignment(
                    dynamicTypeSize.isAccessibilitySize
                        ? .leading
                        : .trailing
                )
        }
    }

    private func accessibilityLabel(
        formattedAmount: String,
        formattedFiatValue: String
    ) -> Text {
        if isBalanceHidden {
            return Text(
                EnglishNumbers.localized(
                    "wallet.accessibility.asset.hidden",
                    asset.name
                )
            )
        }

        return Text(
            EnglishNumbers.localized(
                "wallet.accessibility.asset.balance_and_value",
                asset.name,
                formattedAmount,
                formattedFiatValue
            )
        )
    }
}
