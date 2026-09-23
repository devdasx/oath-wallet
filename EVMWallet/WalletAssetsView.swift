import SwiftUI

struct WalletAssetsView: View {
    let database: WalletDatabase
    let assets: [WalletAsset]
    let transactions: [WalletTransaction]
    let contentRevision: UUID
    let capabilities: WalletCapabilities
    let isBalanceHidden: Bool
    let isVisible: (WalletAsset) -> Bool
    let onVisibilityChanged: (WalletAsset, Bool) -> Void
    let onTokenAdded: (WalletAsset) -> Void
    let onSendAsset: (WalletAsset) -> Void
    let onReceiveAsset: (WalletAsset) -> Void
    let onScanAsset: (WalletAsset) -> Void
    let onPasteAsset: (WalletAsset, String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var searchText = ""
    @State private var selectedNetworkID: String?
    @State private var isManageAssetsPresented: Bool
    @State private var listPreparation:
        WalletAssetListPreparation?
    @State private var preparedSections:
        [WalletAssetSelectionCatalog.Section]
    @State private var isPreparingCatalog: Bool
    @State private var appliedCatalogRequest: CatalogRequest?
    @State private var preparedContentRevision: UUID?

    init(
        database: WalletDatabase,
        assets: [WalletAsset],
        transactions: [WalletTransaction],
        preparation: WalletAssetListPreparation? = nil,
        contentRevision: UUID = UUID(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        ),
        initialNetworkID: String? = nil,
        initiallyPresentsManagement: Bool = false,
        capabilities: WalletCapabilities = .fullWallet,
        isBalanceHidden: Bool,
        isVisible: @escaping (WalletAsset) -> Bool,
        onVisibilityChanged: @escaping (WalletAsset, Bool) -> Void,
        onTokenAdded: @escaping (WalletAsset) -> Void,
        onSendAsset: @escaping (WalletAsset) -> Void,
        onReceiveAsset: @escaping (WalletAsset) -> Void,
        onScanAsset: @escaping (WalletAsset) -> Void,
        onPasteAsset: @escaping (WalletAsset, String) -> Void
    ) {
        self.database = database
        let scopedAssets = capabilities.filteredAssets(assets)
        let scopedTransactions =
            capabilities.filteredTransactions(transactions)
        self.assets = scopedAssets
        self.transactions = scopedTransactions
        self.contentRevision = contentRevision
        self.capabilities = capabilities
        self.isBalanceHidden = isBalanceHidden
        self.isVisible = isVisible
        self.onVisibilityChanged = onVisibilityChanged
        self.onTokenAdded = onTokenAdded
        self.onSendAsset = onSendAsset
        self.onReceiveAsset = onReceiveAsset
        self.onScanAsset = onScanAsset
        self.onPasteAsset = onPasteAsset

        _listPreparation = State(initialValue: preparation)
        _selectedNetworkID = State(
            initialValue: initialNetworkID
                ?? preparation?.initialNetworkID
                ?? (
                    capabilities.showsNetworkSelector
                        ? nil
                        : capabilities.privateKeyNetwork?.networkID
                )
        )
        _preparedSections = State(
            initialValue: preparation?.initialBrowseSections ?? []
        )
        _isPreparingCatalog = State(
            initialValue: preparation == nil
        )
        _isManageAssetsPresented = State(
            initialValue: initiallyPresentsManagement
        )
        _appliedCatalogRequest = State(
            initialValue: preparation.map {
                CatalogRequest(
                    searchText: "",
                    networkID: $0.initialNetworkID,
                    assetCount: scopedAssets.count,
                    transactionCount: scopedTransactions.count,
                    contentRevision: contentRevision,
                    isIndexReady: true
                )
            }
        )
        _preparedContentRevision = State(
            initialValue: preparation == nil ? nil : contentRevision
        )
    }

    var body: some View {
        let balanceSnapshot = WalletAssetBalanceSnapshot(assets: assets)
        List {
            Group {
                if isPreparingCatalog && preparedSections.isEmpty {
                    Section {
                        Text("wallet.assets.loading.name")
                            .foregroundStyle(.secondary)
                    }
                } else if preparedSections.isEmpty {
                    Section {
                        WalletSearchEmptyStateView()
                    }
                } else if !preparedSections.isEmpty {
                    ForEach(preparedSections) { assetSection in
                        Section(LocalizedStringKey(assetSection.kind.titleKey)) {
                            ForEach(assetSection.groups) { group in
                                let group = resolved(
                                    group,
                                    balances: balanceSnapshot
                                )
                                NavigationLink {
                                    Group {
                                        destination(for: group)
                                    }

                                } label: {
                                    UnifiedAssetSelectionRow(
                                        name: group.name,
                                        symbol: group.symbol,
                                        logoSource: group.logoSource,
                                        networkLogoSource:
                                            group.networkLogoSource,
                                        familyLogoSource:
                                            group.familyLogoSource,
                                        balance: group.balance,
                                        fiatValue: group.fiatValue,
                                        isBalanceHidden: isBalanceHidden
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .navigationTitle("wallet.home.assets.title")
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
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: UniHaptic.action(nil) {
                    isManageAssetsPresented = true
                }) {
                    Image(systemName: "gearshape")
                        .fontWeight(WalletSFSymbol.weight)
                }
                .accessibilityLabel(
                    Text("wallet.assets.manage.accessibility")
                )
            }
        }
        .navigationDestination(isPresented: $isManageAssetsPresented) {
            WalletManageAssetsView(
                database: database,
                assets: assets,
                transactions: transactions,
                preparation: listPreparation,
                capabilities: capabilities,
                isVisible: isVisible,
                onVisibilityChanged: onVisibilityChanged,
                onTokenAdded: onTokenAdded
            )
        }
        .task(id: catalogRequest) {
            await ensureListPreparation()
            await prepareCatalog()
        }
    }

    private func resolved(
        _ group: WalletAssetSelectionGroup,
        balances: WalletAssetBalanceSnapshot
    ) -> WalletAssetSelectionGroup {
        WalletAssetSelectionGroup(
            id: group.id,
            token: group.token,
            name: group.name,
            symbol: group.symbol,
            assets: group.assets.map(balances.resolved)
        )
    }

    @ViewBuilder
    private func destination(
        for group: WalletAssetSelectionGroup
    ) -> some View {
        if let asset = group.assets.first {
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
            .onAppear {
                guard !isVisible(asset) else { return }
                onVisibilityChanged(asset, true)
            }
        }
    }

    private var catalogRequest: CatalogRequest {
        CatalogRequest(
            searchText: searchText,
            networkID: selectedNetworkID,
            assetCount: assets.count,
            transactionCount: transactions.count,
            contentRevision: contentRevision,
            isIndexReady: listPreparation != nil
        )
    }

    @MainActor
    private func prepareCatalog() async {
        guard let listPreparation else { return }
        let request = catalogRequest
        guard appliedCatalogRequest != request else { return }
        if preparedSections.isEmpty {
            isPreparingCatalog = true
        }
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
            Self.sections(
                index: listPreparation.browseIndex,
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

    nonisolated private static func sections(
        index: WalletAssetDiscoveryIndex,
        networkID: String?,
        searchText: String
    ) -> [WalletAssetSelectionCatalog.Section] {
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
        return WalletAssetSelectionCatalog.sections(
            fromOrderedAssets: orderedAssets
        )
    }

    @MainActor
    private func ensureListPreparation() async {
        if preparedContentRevision != contentRevision {
            listPreparation = nil
            appliedCatalogRequest = nil
            preparedContentRevision = nil
        }
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
        preparedContentRevision = contentRevision
        selectedNetworkID = preparation.initialNetworkID
        apply(
            preparation.initialBrowseSections,
            request: catalogRequest
        )
    }

    @MainActor
    private func apply(
        _ sections: [WalletAssetSelectionCatalog.Section],
        request: CatalogRequest
    ) {
        let currentIDs = preparedSections.flatMap(\.groups).map(\.id)
        let updatedIDs = sections.flatMap(\.groups).map(\.id)
        AssetListRenderingWindow.replaceBalanceRankedResults(
            currentIDs: currentIDs,
            updatedIDs: updatedIDs,
            reduceMotion: reduceMotion
        ) {
            preparedSections = sections
            isPreparingCatalog = false
            appliedCatalogRequest = request
        }
    }

}

private struct CatalogRequest: Hashable {
    let searchText: String
    let networkID: String?
    let assetCount: Int
    let transactionCount: Int
    let contentRevision: UUID
    let isIndexReady: Bool
}
