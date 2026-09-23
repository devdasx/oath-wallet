import SwiftUI

struct WalletUniversalSearchTextRow: View {
    let title: LocalizedStringKey
    let subtitle: Text
    let action: WalletUniversalSearchAction

    var body: some View {
        HStack(spacing: 12) {
            WalletUniversalSearchActionIcon(action: action)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(WalletTheme.primaryLabel)

                subtitle
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct WalletUniversalSearchWalletRow: View {
    let wallet: ManagedWallet

    @Environment(\.walletCurrencyContext) private var currencyContext

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: wallet.name)
                    .foregroundStyle(WalletTheme.primaryLabel)

                Text(
                    wallet.isSelected
                        ? "wallet.search.wallet.current"
                        : "wallet.search.wallet.switch"
                )
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)
            }

            Spacer(minLength: 8)

            Text(
                EnglishNumbers.currency(
                    wallet.fiatUSDBalance,
                    using: currencyContext
                )
            )
            .foregroundStyle(WalletTheme.secondaryLabel)
            .monospacedDigit()
        }
        .contentShape(Rectangle())
    }
}

enum WalletUniversalSearchNetworkPresentation {
    static func title(
        for network: AssetNetworkSelectorOption
    ) -> String {
        EnglishNumbers.localized(
            "wallet.search.network.subtitle",
            network.localizedName
        )
    }
}

struct WalletUniversalSearchNetworkRow: View {
    let network: AssetNetworkSelectorOption

    var body: some View {
        HStack(spacing: 12) {
            OfficialNetworkLogoView(
                assetName: network.officialLogoAssetName,
                size: 42
            )

            Text(
                verbatim: WalletUniversalSearchNetworkPresentation
                    .title(for: network)
            )
            .foregroundStyle(WalletTheme.primaryLabel)

            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct WalletUniversalSearchAssetRow: View {
    let asset: WalletAsset
    let unitUSDPrice: Decimal?
    let isBalanceHidden: Bool
    var showsUnavailablePrice = false

    @Environment(\.walletCurrencyContext) private var currencyContext

    var body: some View {
        HStack(spacing: 12) {
            WalletAssetLogoWithNetworkBadge(
                asset: asset,
                size: 42
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: asset.name)
                    .foregroundStyle(WalletTheme.primaryLabel)
                    .lineLimit(1)

                Text(verbatim: identitySubtitle)
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let unitUSDPrice {
                WalletPrivacyReplacement(
                    isHidden: isBalanceHidden
                ) {
                    Text(
                        EnglishNumbers.currency(
                            unitUSDPrice,
                            using: currencyContext
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .monospacedDigit()
                    .lineLimit(1)
                }
            } else if showsUnavailablePrice {
                Text(verbatim: EnglishNumbers.currency(0, using: currencyContext))
                    .foregroundStyle(WalletTheme.secondaryLabel)
            }
        }
        .contentShape(Rectangle())
    }

    private var identitySubtitle: String {
        let networkName =
            WalletAssetSelectionCatalog.networkName(for: asset)
            ?? WalletLocalization.string(
                "wallet.search.asset.network.unavailable"
            )
        return "\(asset.symbol) · \(networkName)"
    }

}

private struct WalletUniversalSearchActionIcon: View {
    let action: WalletUniversalSearchAction

    @ScaledMetric(relativeTo: .body)
    private var size = WalletIconTileStyle.size

    var body: some View {
        let presentation = iconPresentation
        WalletIconTile(
            systemImage: presentation.systemImage,
            color: presentation.color,
            size: size
        )
    }

    private var iconPresentation: (
        systemImage: String,
        color: Color
    ) {
        switch action {
        case .send:
            ("arrow.up", WalletTheme.settingsIconBlue)
        case .receive:
            ("arrow.down", WalletTheme.settingsIconGreen)
        case .scan:
            ("qrcode.viewfinder", WalletTheme.settingsIconOrange)
        case .allAssets:
            ("square.grid.2x2.fill", WalletTheme.settingsIconIndigo)
        case .manageAssets:
            ("slider.horizontal.3", WalletTheme.settingsIconBlue)
        case .allActivity:
            ("clock.arrow.circlepath", WalletTheme.settingsIconOrange)
        case .walletSwitcher:
            settingsPresentation(.wallets)
        case let .settings(route):
            settingsPresentation(for: route)
        }
    }

    private func settingsPresentation(
        for route: WalletSettingsSearchRoute
    ) -> (systemImage: String, color: Color) {
        switch route {
        case .root:
            ("gearshape.fill", WalletTheme.settingsIconGray)
        case .wallets:
            settingsPresentation(.wallets)
        case .security, .deviceMigrationExport:
            settingsPresentation(.security)
        case .appearance:
            settingsPresentation(.appearance)
        case .language:
            settingsPresentation(.language)
        case .currency:
            settingsPresentation(.currency)
        case .backupAndKeys, .backupMaterial, .backupMethod:
            (
                "externaldrive.badge.icloud",
                WalletTheme.settingsIconBlue
            )
        case .tools:
            settingsPresentation(.tools)
        case .currencyConverter:
            settingsPresentation(.currencyConverter)
        case .networkFeeDashboard, .networkFeeDetails:
            settingsPresentation(.networkFees)
        case .transactionExport:
            settingsPresentation(.transactionExport)
        case .bitcoinTransactionBroadcaster:
            settingsPresentation(.bitcoinTransactionBroadcaster)
        case .mnemonicLastWordFinder:
            settingsPresentation(.mnemonicLastWordFinder)
        case .evmAccessManager, .evmApprovalReview:
            settingsPresentation(.evmAccessManager)
        case .notifications:
            settingsPresentation(.notifications)
        case .about:
            settingsPresentation(.about)
        case .reset:
            settingsPresentation(.reset)
        }
    }

    private func settingsPresentation(
        _ icon: SettingsRowIcon
    ) -> (systemImage: String, color: Color) {
        (icon.systemImage, icon.color)
    }
}
