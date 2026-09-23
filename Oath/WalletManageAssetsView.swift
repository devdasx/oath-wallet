import SwiftUI

struct WalletManageAssetsView: View {
    let database: WalletDatabase
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]
    let capabilities: WalletCapabilities
    let isVisible: (WalletAsset) -> Bool
    let onVisibilityChanged: (WalletAsset, Bool) -> Void
    let onTokenAdded: (WalletAsset) -> Void

    @State private var searchText = ""
    @State private var selectedNetworkID: String?
    @State private var listPreparation:
        WalletAssetListPreparation?
    @State private var preparedGroups: [WalletAssetSelectionGroup]
    @State private var isPreparingCatalog: Bool
    @State private var isAddTokenPresented = false
    @State private var appliedCatalogRequest:
        ManageAssetCatalogRequest?

    init(
        database: WalletDatabase,
        assets: [WalletAsset],
        transactions: [WalletTransaction],
        preparation: WalletAssetListPreparation? = nil,
        capabilities: WalletCapabilities = .fullWallet,
        isVisible: @escaping (WalletAsset) -> Bool,
        onVisibilityChanged: @escaping (WalletAsset, Bool) -> Void,
        onTokenAdded: @escaping (WalletAsset) -> Void
    ) {
        self.database = database
        let scopedAssets = capabilities.filteredAssets(assets)
        let scopedTransactions =
            capabilities.filteredTransactions(transactions)
        self.assets = scopedAssets
        self.transactions = scopedTransactions
        self.capabilities = capabilities
        self.isVisible = isVisible
        self.onVisibilityChanged = onVisibilityChanged
        self.onTokenAdded = onTokenAdded

        _listPreparation = State(initialValue: preparation)
        _selectedNetworkID = State(
            initialValue: preparation?.initialNetworkID
                ?? (
                    capabilities.showsNetworkSelector
                        ? nil
                        : capabilities.privateKeyNetwork?.networkID
                )
        )
        _preparedGroups = State(
            initialValue: preparation?.initialManageGroups ?? []
        )
        _isPreparingCatalog = State(
            initialValue: preparation == nil
        )
        _appliedCatalogRequest = State(
            initialValue: preparation.map {
                ManageAssetCatalogRequest(
                    searchText: "",
                    networkID: $0.initialNetworkID,
                    assetCount: scopedAssets.count,
                    transactionCount: scopedTransactions.count,
                    isIndexReady: true
                )
            }
        )
    }

    var body: some View {
        List {
            Group {
                if isPreparingCatalog && preparedGroups.isEmpty {
                    Section {
                        Text("wallet.assets.loading.name")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if preparedGroups.isEmpty {
                            WalletSearchEmptyStateView()
                        } else {
                            ForEach(preparedGroups) { group in
                                if let asset = group.assets.first {
                                    HStack(spacing: 12) {
                                        UnifiedAssetSelectionRow(
                                            name: group.name,
                                            symbol: group.symbol,
                                            logoSource: group.logoSource,
                                            networkLogoSource:
                                                group.networkLogoSource,
                                            familyLogoSource:
                                                group.familyLogoSource,
                                            balance: nil,
                                            fiatValue: nil,
                                            isBalanceHidden: false
                                        )

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
                        }
                    } footer: {
                        Text("wallet.assets.manage.footer")
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("wallet.assets.manage.title")
        .navigationBarTitleDisplayMode(.inline)
        .assetNetworkAppBar(
            isPresented: capabilities.showsNetworkSelector,
            options: capabilities.selectorOptions,
            selectedNetworkID: $selectedNetworkID,
            ordering:
                listPreparation?.networkSelectionOrdering
                ?? .catalogOrder
        )
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("wallet.assets.manage.search")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .toolbar {
            if canAddCustomToken {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: UniHaptic.action(nil) {
                        isAddTokenPresented = true
                    }) {
                        Label {
                            Text("wallet.assets.add_token.action")
                        } icon: {
                            Image(systemName: "plus")
                                .fontWeight(WalletSFSymbol.weight)
                        }
                        .labelStyle(.titleAndIcon)
                    }
                    .accessibilityHint(
                        Text("wallet.assets.add_token.action.hint")
                    )
                }
            }
        }
        .sheet(isPresented: $isAddTokenPresented) {
            NavigationStack {
                Group {
                    AddTokenNetworkSelectionView(
                        database: database,
                        walletAssets: assets,
                        transactions: transactions,
                        capabilities: capabilities,
                        onTokenSaved: { asset in
                            onTokenAdded(asset)
                            isAddTokenPresented = false
                        }
                    )
                }

            }
            .walletSheetPresentation(nativeGlass: false)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: ManageAssetCatalogRequest(
            searchText: searchText,
            networkID: selectedNetworkID,
            assetCount: assets.count,
            transactionCount: transactions.count,
            isIndexReady: listPreparation != nil
        )) {
            await ensureListPreparation()
            await prepareCatalog()
        }
    }

    private var canAddCustomToken: Bool {
        !AddTokenNetworkSelectionView.supportedNetworks(
            for: capabilities
        ).isEmpty
    }

    @MainActor
    private func prepareCatalog() async {
        guard let listPreparation else { return }
        let request = ManageAssetCatalogRequest(
            searchText: searchText,
            networkID: selectedNetworkID,
            assetCount: assets.count,
            transactionCount: transactions.count,
            isIndexReady: true
        )
        guard appliedCatalogRequest != request else { return }
        if !searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
        }
        let query = searchText
        let networkID = selectedNetworkID
        let worker = Task.detached(priority: .userInitiated) {
            Self.groups(
                index: listPreparation.manageIndex,
                networkID: networkID,
                searchText: query
            )
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        apply(result, request: request)
    }

    nonisolated private static func groups(
        index: WalletAssetDiscoveryIndex,
        networkID: String?,
        searchText: String
    ) -> [WalletAssetSelectionGroup] {
        let visibleLimit = networkID == nil
            ? ReceiveAssetSearchIndex.maximumVisibleResults
            : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
        let orderedAssets = Array(
            index.assets(
                networkID: networkID,
                searchText: searchText
            )
            .prefix(visibleLimit)
        )
        return WalletAssetSelectionCatalog.groups(
            fromOrderedAssets: orderedAssets
        )
    }

    @MainActor
    private func ensureListPreparation() async {
        guard listPreparation == nil else { return }
        let visibleAssetIDs = Set(
            assets.filter(isVisible).map {
                AssetIdentityKey.canonical($0.id)
            }
        )
        let assets = assets
        let transactions = transactions
        let capabilities = capabilities
        let worker = Task.detached(priority: .userInitiated) {
            await WalletAssetListPreparation.make(
                assets: assets,
                transactions: transactions,
                capabilities: capabilities,
                visibleAssetIDs: visibleAssetIDs
            )
        }
        let preparation = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        listPreparation = preparation
        selectedNetworkID = preparation.initialNetworkID
        apply(
            preparation.initialManageGroups,
            request: ManageAssetCatalogRequest(
                searchText: searchText,
                networkID: preparation.initialNetworkID,
                assetCount: assets.count,
                transactionCount: transactions.count,
                isIndexReady: true
            )
        )
    }

    @MainActor
    private func apply(
        _ groups: [WalletAssetSelectionGroup],
        request: ManageAssetCatalogRequest
    ) {
        AssetListRenderingWindow.updateWithoutAnimation {
            preparedGroups = groups
            isPreparingCatalog = false
            appliedCatalogRequest = request
        }
    }

}

private struct ManageAssetCatalogRequest: Hashable {
    let searchText: String
    let networkID: String?
    let assetCount: Int
    let transactionCount: Int
    let isIndexReady: Bool
}
