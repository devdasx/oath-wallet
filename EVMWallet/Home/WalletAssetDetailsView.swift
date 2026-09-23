import SwiftUI

struct WalletAssetDetailsView: View {
    private static let recentActivityLimit = 5

    let database: WalletDatabase
    let asset: WalletAsset
    let transactions: [WalletTransaction]
    let isBalanceHidden: Bool
    let onSend: (WalletAsset) -> Void
    let onReceive: () -> Void
    let onScan: (WalletAsset) -> Void
    let onPaste: (WalletAsset, String) -> Void
    var marketStore: MarketStore = .shared
    var marketDiscovery: MarketDiscoveryStore = .shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.walletCurrencyContext) private var currencyContext
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 72
    @State private var fetchedUnitPriceUSD: Decimal?
    @State private var isLoadingUnitPrice = false
    @State private var refreshedContent: WalletAssetDetailsRefreshContent?

    @State private var showsSilentPaymentLimitation = false
    @State private var bitcoinSettingsWalletID: String?
    @State private var isBitcoinSettingsPresented = false

    var body: some View {
        let activityTransactions = matchingTransactions
        let recentTransactions = activityTransactions.prefix(
            Self.recentActivityLimit
        )

        List {
            Group {
                Section {
                    assetHeader
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                }
                .walletZeroHorizontalListSectionMargins()

                if showsSilentPaymentLimitation {
                    Section {
                        Text("bitcoin.silent.known_outputs_only")
                            .font(.footnote)
                            .foregroundStyle(WalletTheme.secondaryLabel)
                    }
                }

                Section {
                    NavigationLink {
                        let coin = MarketCoin.forAsset(displayedAsset)
                        MarketDetailView(
                            coin: coin,
                            store: marketStore,
                            discovery: marketDiscovery
                        )
                        .task(id: coin.id) {
                            await marketStore.loadCache()
                            let updatedAt = marketStore.records[coin.id]?.quote?.updatedAt ?? .distantPast
                            if Date().timeIntervalSince(updatedAt) > 180 {
                                await marketStore.refresh(coins: [coin])
                            }
                        }
                    } label: {
                        LabeledContent {
                            if isLoadingUnitPrice, resolvedUnitPriceUSD == nil {
                                Text("wallet.asset.details.price.loading")
                                    .foregroundStyle(WalletTheme.secondaryLabel)
                            } else {
                                privateValue(
                                    visibleValue: formattedUnitPrice,
                                    alignment: .trailing
                                )
                            }
                        } label: {
                            Text("wallet.asset.details.price")
                                .foregroundStyle(WalletTheme.primaryLabel)
                        }
                    }
                    .accessibilityIdentifier("walletAssetDetailsMarketPrice")
                }

                Section {
                    if activityTransactions.isEmpty {
                        WalletEmptyStateView(
                            "wallet.asset.details.activity.empty.title",
                            message: "wallet.asset.details.activity.empty.message"
                        )
                        .frame(maxWidth: .infinity)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(recentTransactions) { transaction in
                            NavigationLink {
                                Group {
                                    WalletTransactionDetailsView(
                                        transaction: transaction,
                                        isBalanceHidden: isBalanceHidden
                                    )
                                }

                            } label: {
                                WalletTransactionRow(
                                    transaction: transaction,
                                    isBalanceHidden: isBalanceHidden
                                )
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("wallet.home.activity.title")

                        Spacer()

                        if activityTransactions.count >
                            Self.recentActivityLimit {
                            NavigationLink {
                                Group {
                                    WalletActivityView(
                                        transactions: activityTransactions,
                                        networkValueAssets: [displayedAsset],
                                        isBalanceHidden: isBalanceHidden
                                    )
                                }

                            } label: {
                                Text("common.see_all")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(WalletTheme.secondaryLabel)
                                    .textCase(nil)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                Text(
                                    "wallet.home.activity.see_all.accessibility"
                                )
                            )
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WalletTheme.groupedBackground)
        .navigationTitle(displayedAsset.name)

        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if bitcoinSettingsWalletID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: UniHaptic.action(nil) {
                        isBitcoinSettingsPresented = true
                    }) {
                        Image(systemName: "slider.horizontal.3")
                            .fontWeight(WalletSFSymbol.weight)
                    }
                    .accessibilityLabel(Text("settings.title"))
                    .accessibilityIdentifier(
                        "walletAssetDetailsBitcoinSettings"
                    )
                }
            }
        }
        .refreshable {
            await refreshCurrentAsset()
        }
        .task(id: asset.id) {
            await refreshCurrentAsset()
        }
        .task(id: bitcoinSettingsRequestIdentity) {
            await prepareBitcoinSettings()
        }
        .sheet(isPresented: $isBitcoinSettingsPresented) {
            if let bitcoinSettingsWalletID {
                BitcoinWalletSettingsFlow(
                    walletID: bitcoinSettingsWalletID,
                    database: database
                )
                .presentationDetents([.large])
            }
        }
    }

    private var displayedAsset: WalletAsset {
        refreshedContent?.asset ?? asset
    }

    private var displayedTransactions: [WalletTransaction] {
        refreshedContent?.transactions ?? transactions
    }

    private var isNativeBitcoinAsset: Bool {
        guard case .nativeCoin(.bitcoin) = displayedAsset.logoSource else {
            return false
        }
        return true
    }

    private var bitcoinSettingsRequestIdentity: String {
        "\(displayedAsset.id):\(isNativeBitcoinAsset)"
    }

    private var assetHeader: some View {
        VStack(spacing: 18) {
            VStack(spacing: 18) {
                WalletAssetLogoWithNetworkBadge(
                    asset: displayedAsset,
                    size: min(logoSize, 96)
                )

                VStack(spacing: 5) {
                    Text(verbatim: displayedAsset.name)
                        .font(
                            .title2.weight(
                                WalletTypography.contentTitleWeight
                            )
                        )
                        .multilineTextAlignment(.center)

                    Text(
                        EnglishNumbers.localized(
                            "wallet.asset.details.identity",
                            displayedAsset.symbol,
                            networkName
                        )
                    )
                    .font(.subheadline)
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .multilineTextAlignment(.center)
                }

                WalletAssetDetailsBalanceView(
                    localValueUSD: resolvedLocalValueUSD,
                    formattedAssetAmount: formattedAssetAmount,
                    currencyContext: currencyContext,
                    isBalanceHidden: isBalanceHidden
                )
            }
            .frame(
                maxWidth: horizontalSizeClass == .regular ? 560 : .infinity
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)

            assetActions
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 18)
        .padding(.bottom, 22)
        .accessibilityElement(children: .contain)
    }

    private var assetActions: some View {
        WalletPrimaryActionGroup {
            sendButton
            receiveButton
            moreMenu
        }
    }

    private var sendButton: some View {
        MutedWalletActionButton(
            title: "wallet.home.action.send",
            prominence: .primary,
            hapticPolicy: .silent,
            action: {
                onSend(displayedAsset)
            }
        )
        .accessibilityIdentifier("walletAssetDetailsSend")
    }

    private var receiveButton: some View {
        MutedWalletActionButton(
            title: "wallet.home.action.receive",
            prominence: .secondary,
            hapticPolicy: .silent,
            action: onReceive
        )
        .accessibilityIdentifier("walletAssetDetailsReceive")
    }

    private var moreMenu: some View {
        WalletHomeMoreActionMenu(
            onScan: {
                onScan(displayedAsset)
            },
            onPasteAddress: { payload in
                onPaste(displayedAsset, payload)
            }
        )
        .accessibilityIdentifier("walletAssetDetailsMore")
    }

    private func privateValue(
        visibleValue: String,
        alignment: Alignment
    ) -> some View {
        WalletPrivacyReplacement(
            isHidden: isBalanceHidden,
            alignment: alignment
        ) {
            Text(visibleValue)
                .foregroundStyle(WalletTheme.secondaryLabel)
        }
    }

    private var networkName: String {
        guard let network = displayedAsset.network else {
            return WalletLocalization.string(
                "wallet.asset.details.unavailable"
            )
        }

        let name = ReceiveNetworkCatalog.all.first {
            $0.blockchain == network
        }?.localizedName
            ?? network.rawValue.capitalized
        // A family member names its family before its chain.
        guard let family = displayedAsset.family else { return name }
        return "\(family.localizedName) · \(name)"
    }

    private var formattedAssetAmount: String {
        EnglishNumbers.localized(
            "wallet.format.asset_amount",
            displayedAsset.displayBalanceText,
            displayedAsset.symbol
        )
    }

    private var formattedUnitPrice: String {
        guard let price = resolvedUnitPriceUSD else {
            return EnglishNumbers.currency(0, using: currencyContext)
        }

        return EnglishNumbers.unitPrice(
            price,
            using: currencyContext
        )
    }

    private var resolvedUnitPriceUSD: Decimal? {
        if let fetchedUnitPriceUSD, fetchedUnitPriceUSD > 0 {
            return fetchedUnitPriceUSD
        }
        guard displayedAsset.balance != 0 else { return nil }
        let impliedPrice = displayedAsset.fiatValue / displayedAsset.balance
        return impliedPrice > 0 ? impliedPrice : nil
    }

    private var resolvedLocalValueUSD: Decimal {
        if let fetchedUnitPriceUSD, fetchedUnitPriceUSD > 0 {
            return displayedAsset.balance * fetchedUnitPriceUSD
        }
        if displayedAsset.fiatValue != 0 {
            return displayedAsset.fiatValue
        }
        guard let price = resolvedUnitPriceUSD else { return 0 }
        return displayedAsset.balance * price
    }

    @MainActor
    private func refreshCurrentAsset() async {
        async let priceLoad: Void = loadUnitPrice()
        async let detailsLoad: Void = refreshAssetDetails()
        _ = await (priceLoad, detailsLoad)
    }

    @MainActor
    private func prepareBitcoinSettings() async {
        showsSilentPaymentLimitation = false
        guard isNativeBitcoinAsset else {
            bitcoinSettingsWalletID = nil
            isBitcoinSettingsPresented = false
            return
        }

        do {
            guard let identity = try await database.selectedWalletIdentity()
            else {
                bitcoinSettingsWalletID = nil
                return
            }

            let wallet = try await database.managedWallet(
                walletID: identity.walletID
            )
            try Task.checkCancellation()

            guard wallet.kind.hasRecoveryPhrase else {
                bitcoinSettingsWalletID = nil
                return
            }

            bitcoinSettingsWalletID = identity.walletID
            // A phrase restore can have undiscovered outputs without a local account.
            showsSilentPaymentLimitation = true
        } catch is CancellationError {
            return
        } catch {
            bitcoinSettingsWalletID = nil
        }
    }

    @MainActor
    private func loadUnitPrice() async {
        guard let identity = try? await database.selectedWalletIdentity() else { return }
        do { try Task.checkCancellation() }
        catch { return }
        isLoadingUnitPrice = true
        defer { isLoadingUnitPrice = false }
        guard let quote = try? await AssetPriceClient.shared.usdPrice(
            for: displayedAsset
        ) else {
            return
        }
        fetchedUnitPriceUSD = quote.price
    }

    @MainActor
    private func refreshAssetDetails() async {
        do {
            let content = try await WalletAssetDetailsRefreshService.shared
                .refresh(asset: asset)
            try Task.checkCancellation()
            refreshedContent = content
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    private var matchingTransactions: [WalletTransaction] {
        WalletAssetDetailsSelection.transactions(
            from: displayedTransactions,
            matching: displayedAsset
        )
    }

}

struct WalletAssetDetailsBalanceView: View {
    let localValueUSD: Decimal
    let formattedAssetAmount: String
    let currencyContext: WalletCurrencyContext
    let isBalanceHidden: Bool

    var body: some View {
        VStack(spacing: 6) {
            WalletHeroCurrencyBalance(
                usdValue: localValueUSD,
                currencyContext: currencyContext,
                isHidden: isBalanceHidden,
                fontSize: 52,
                minimumHeight: 62
            )
            .accessibilityIdentifier(
                "walletAssetDetailsLocalBalance"
            )

            WalletPrivacyReplacement(
                isHidden: isBalanceHidden
            ) {
                Text(formattedAssetAmount)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(WalletTheme.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .accessibilityIdentifier(
                "walletAssetDetailsNativeBalance"
            )
        }
    }
}
