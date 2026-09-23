import SwiftUI

struct WalletHomeSearchView: View {
    let database: WalletDatabase
    let query: String
    let index: WalletUniversalSearchIndex?
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]
    let walletAddress: String
    let capabilities: WalletCapabilities
    let isBalanceHidden: Bool
    let onSendAsset: (WalletAsset) -> Void
    let onReceiveAsset: (WalletAsset) -> Void
    let onScanAsset: (WalletAsset) -> Void
    let onPasteAsset: (WalletAsset, String) -> Void
    let onAction: (WalletUniversalSearchAction) -> Void
    let onWalletSelected: (ManagedWallet) -> Void
    let onNetworkSelected: (String) -> Void

    @State private var results = WalletUniversalSearchResults.empty
    @State private var isSearching = false
    @State private var didHistorySearchFail = false
    @State private var liveMarketPrices: [String: Decimal] = [:]

    var body: some View {
        ZStack {
            WalletTheme.groupedBackground
                .ignoresSafeArea()
                .accessibilityHidden(true)

            searchContent
        }
        .task(id: searchRequest) {
            await updateResults()
        }
        .task(id: marketPriceRequest) {
            await updateMarketPrices()
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if normalizedQuery.isEmpty {
            suggestionsContent
        } else if isSearching && results.isEmpty {
            loadingContent
        } else if results.isEmpty && !didHistorySearchFail {
            WalletSearchEmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            resultsList
        }
    }

    private var suggestionsContent: some View {
        List {
            Group {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("wallet.search.start.title")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)

                        Text("wallet.search.start.message")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 10)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }

                if let index {
                    let suggestions = index.suggestions()
                    if !suggestions.actions.isEmpty {
                        Section("wallet.search.section.quick_actions") {
                            ForEach(suggestions.actions) { item in
                                actionButton(item)
                            }
                        }
                    }

                    if !suggestions.marketAssets.isEmpty {
                        Section("wallet.search.section.assets_prices") {
                            ForEach(suggestions.marketAssets) { asset in
                                marketAssetLink(asset)
                            }
                        }
                    }

                    if !suggestions.features.isEmpty {
                        Section("wallet.search.section.actions_settings") {
                            ForEach(suggestions.features) { item in
                                actionButton(item)
                            }
                        }
                    }

                    if !suggestions.settings.isEmpty {
                        Section("settings.section.preferences") {
                            ForEach(suggestions.settings) { item in
                                actionButton(item)
                            }
                        }
                    }

                    if !suggestions.assets.isEmpty {
                        Section("wallet.search.section.portfolio") {
                            ForEach(suggestions.assets) { asset in
                                assetLink(asset)
                            }
                        }
                    }
                } else {
                    Section("wallet.search.section.preparing") {
                        Text("wallet.search.section.preparing")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .walletUniversalSearchListStyle()
    }

    private var loadingContent: some View {
        List {
            Group {
                Section("wallet.search.section.searching") {
                    Text("wallet.search.section.searching")
                        .foregroundStyle(.secondary)
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .walletUniversalSearchListStyle()
    }

    private var resultsList: some View {
        List {
            Group {
                if !results.actions.isEmpty {
                    Section("wallet.search.section.actions_settings") {
                        ForEach(results.actions) { item in
                            actionButton(item)
                        }
                    }
                }

                if !results.wallets.isEmpty {
                    Section("wallet.search.section.wallets") {
                        ForEach(results.wallets) { wallet in
                            Button(action: UniHaptic.action(nil) {
                                onWalletSelected(wallet)
                            }) {
                                WalletUniversalSearchWalletRow(
                                    wallet: wallet
                                )
                            }
                            .buttonStyle(.automatic)
                        }
                    }
                }

                if !results.networks.isEmpty {
                    Section("wallet.search.section.networks") {
                        ForEach(results.networks) { network in
                            Button(action: UniHaptic.action(nil) {
                                UniHaptic.play(.selection)
                                onNetworkSelected(network.id)
                            }) {
                                WalletUniversalSearchNetworkRow(
                                    network: network
                                )
                            }
                            .buttonStyle(.automatic)
                        }
                    }
                }

                if !results.assets.isEmpty {
                    Section("wallet.search.section.assets_prices") {
                        ForEach(results.assets) { asset in
                            assetLink(asset)
                        }
                    }
                }

                if !results.transactions.isEmpty {
                    Section("wallet.search.section.activity") {
                        ForEach(results.transactions) { transaction in
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
                }

                if didHistorySearchFail {
                    Section("wallet.search.section.activity") {
                        Text("wallet.search.history.unavailable")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .walletUniversalSearchListStyle()
    }

    private func actionButton(
        _ item: WalletUniversalSearchActionItem
    ) -> some View {
        Button(action: UniHaptic.action {
            UniHaptic.play(.selection)
            onAction(item.action)
        }) {
            WalletUniversalSearchTextRow(
                title: LocalizedStringKey(item.titleKey),
                subtitle: actionSubtitle(for: item),
                action: item.action
            )
        }
        .buttonStyle(.automatic)
    }

    private func actionSubtitle(
        for item: WalletUniversalSearchActionItem
    ) -> Text {
        if let subtitleText = item.subtitleText {
            return Text(verbatim: subtitleText)
        }

        return Text(LocalizedStringKey(item.subtitleKey))
    }

    private func assetLink(
        _ asset: WalletAsset
    ) -> some View {
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
            WalletUniversalSearchAssetRow(
                asset: asset,
                unitUSDPrice: displayedUnitPrice(for: asset),
                isBalanceHidden: isBalanceHidden
            )
        }
    }

    private func marketAssetLink(
        _ asset: WalletAsset
    ) -> some View {
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
            WalletUniversalSearchAssetRow(
                asset: asset,
                unitUSDPrice: displayedUnitPrice(for: asset),
                isBalanceHidden: false,
                showsUnavailablePrice: true
            )
        }
    }

    private func displayedUnitPrice(
        for asset: WalletAsset
    ) -> Decimal? {
        liveMarketPrices[AssetIdentityKey.canonical(asset.id)]
            ?? index?.unitUSDPrice(for: asset)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRequest: SearchRequest {
        SearchRequest(
            query: normalizedQuery,
            indexRevision: index?.revision,
            walletAddress: walletAddress
        )
    }

    private var marketPriceRequest: MarketPriceRequest {
        MarketPriceRequest(
            indexRevision: index?.revision,
            showsSuggestions: normalizedQuery.isEmpty
        )
    }

    @MainActor
    private func updateMarketPrices() async {
        guard normalizedQuery.isEmpty, let index else { return }
        let marketAssets = index.suggestions().marketAssets
        guard !marketAssets.isEmpty else { return }

        let prices = await AssetPriceClient.usdPrices(
            for: marketAssets,
            maximumConcurrentRequests: marketAssets.count
        )
        guard !Task.isCancelled else { return }
        liveMarketPrices = Dictionary(
            prices.map {
                (AssetIdentityKey.canonical($0.key), $0.value)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    @MainActor
    private func updateResults() async {
        let query = normalizedQuery
        guard !query.isEmpty, let index else {
            results = .empty
            isSearching = false
            didHistorySearchFail = false
            return
        }

        isSearching = true
        async let localResultsTask = Task.detached(
            priority: .userInitiated
        ) {
            index.localResults(matching: query)
        }.value
        async let transactionResultsTask =
            database.universalSearchTransactions(
                matching: query
            )

        let localResults = await localResultsTask
        let transactionResults: [WalletTransaction]
        let historySearchFailed: Bool
        do {
            transactionResults = try await transactionResultsTask
            historySearchFailed = false
        } catch {
            transactionResults = []
            historySearchFailed = true
        }
        guard !Task.isCancelled else { return }

        didHistorySearchFail = historySearchFailed
        results = WalletUniversalSearchResults(
            actions: localResults.actions,
            wallets: localResults.wallets,
            networks: localResults.networks,
            assets: capabilities.filteredAssets(
                localResults.assets
            ),
            transactions: capabilities.filteredTransactions(
                transactionResults
            )
        )
        isSearching = false
    }

    private struct SearchRequest: Hashable {
        let query: String
        let indexRevision: UUID?
        let walletAddress: String
    }

    private struct MarketPriceRequest: Hashable {
        let indexRevision: UUID?
        let showsSuggestions: Bool
    }
}

private extension View {
    func walletUniversalSearchListStyle() -> some View {
        listStyle(.insetGrouped)
    }
}
