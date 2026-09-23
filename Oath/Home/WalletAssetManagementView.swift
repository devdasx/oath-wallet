import SwiftUI

private struct WalletAssetManagementView: View {
    let database: WalletDatabase
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]
    let isBalanceHidden: Bool
    let isVisible: (WalletAsset) -> Bool
    let onVisibilityChanged: (WalletAsset, Bool) -> Void
    let onSendAsset: (WalletAsset) -> Void
    let onReceiveAsset: (WalletAsset) -> Void
    let onScanAsset: (WalletAsset) -> Void
    let onPasteAsset: (WalletAsset, String) -> Void

    @State private var searchText = ""

    var body: some View {
        let visibleAssets = filteredAssets

        List {
            Group {
                Section {
                    if visibleAssets.isEmpty {
                        WalletSearchEmptyStateView()
                    } else {
                        ForEach(visibleAssets) { asset in
                            HStack(spacing: 12) {
                                NavigationLink {
                                    Group {
                                        WalletAssetDetailsView(
                                            database: database,
                                            asset: asset,
                                            transactions: transactions,
                                            isBalanceHidden: isBalanceHidden,
                                            onSend: onSendAsset,
                                            onReceive: {
                                                onReceiveAsset(asset)
                                            },
                                            onScan: onScanAsset,
                                            onPaste: onPasteAsset
                                        )
                                    }

                                } label: {
                                    WalletAssetManagementLabel(
                                        asset: asset,
                                        isBalanceHidden: isBalanceHidden
                                    )
                                }
                                .buttonStyle(.automatic)

                                Toggle(
                                    "",
                                    isOn: Binding(
                                        get: { isVisible(asset) },
                                        set: { isEnabled in
                                            UniHaptic.play(.toggle)
                                            onVisibilityChanged(
                                                asset,
                                                isEnabled
                                            )
                                        }
                                    )
                                )
                                .labelsHidden()
                                .accessibilityLabel(
                                    Text(
                                        EnglishNumbers.localized(
                                            "wallet.assets.manage.visibility.accessibility",
                                            asset.name
                                        )
                                    )
                                )
                            }
                        }
                    }
                } footer: {
                    Text("wallet.assets.manage.footer")
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("wallet.assets.manage.title")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("wallet.assets.manage.search")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
    }

    private var filteredAssets: [WalletAsset] {
        let query = AssetDiscoveryRanking.normalized(searchText)
        guard !query.isEmpty else {
            return Array(
                assets.prefix(
                    ReceiveAssetCatalog.defaultVisibleTokenLimit
                )
            )
        }

        return assets.filter { asset in
            AssetDiscoveryRanking.matches(
                normalizedQuery: query,
                document:
                    AssetDiscoveryRanking.searchDocument(for: asset)
            )
        }
    }
}

private struct WalletAssetManagementLabel: View {
    let asset: WalletAsset
    let isBalanceHidden: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.walletCurrencyContext) private var currencyContext

    var body: some View {
        let assetAmount = EnglishNumbers.localized(
            "wallet.format.asset_amount",
            asset.listDisplayBalanceText,
            asset.symbol
        )
        let fiatAmount = asset.formattedWalletFiat(using: currencyContext)

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
                    Text(assetAmount)
                        .lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(WalletTheme.secondaryLabel)

                if dynamicTypeSize.isAccessibilitySize {
                    fiatValue(fiatAmount)
                }
            }

            Spacer(minLength: 8)

            if !dynamicTypeSize.isAccessibilitySize {
                fiatValue(fiatAmount)
            }
        }
    }

    private func fiatValue(_ fiatAmount: String) -> some View {
        WalletPrivacyReplacement(
            isHidden: isBalanceHidden,
            alignment: .trailing
        ) {
            Text(fiatAmount)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(WalletTheme.primaryLabel)
        .multilineTextAlignment(.trailing)
    }
}
