import SwiftUI
struct ReceiveAssetSelectionView: View {
    let database: WalletDatabase
    let walletAddress: String
    let capabilities: WalletCapabilities
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let preparationRevision: UUID
    let onAssetSelected: (WalletAsset) -> Void
    private let walletAssetsByIdentity: [String: WalletAsset]
    private let baseDirectWalletAssets: [WalletAsset]
    private let discoveryIndex: CombinedAssetDiscoveryIndex
    private let networkSelectionOrdering: WalletNetworkSelectionOrdering
    private let receiveAddressesByBlockchain: [WalletBlockchain: String]
    private let solanaAccounts: SolanaAccountSet?
    private let eligibleSolanaTokenMints: Set<String>
    @State private var searchText = ""
    @State private var selectedNetworkID: String?
    @State private var filteredSelections: [AssetDiscoverySelection]
    @State private var visibleSelectionCount: Int
    @State private var hasRenderedInitialFrame = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(WalletSettingsStore.self) private var applicationSettings
    init(
        database: WalletDatabase,
        walletAddress: String,
        capabilities: WalletCapabilities = .fullWallet,
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction] = [],
        preparation: ReceiveAssetSelectionPreparation? = nil,
        preparationRevision: UUID,
        projection: WalletAssetSelectionProjection? = nil,
        onAssetSelected: @escaping (WalletAsset) -> Void = { _ in }
    ) {
        self.database = database
        self.walletAddress = walletAddress
        let prepared = preparation
            ?? ReceiveAssetSelectionPreparation.make(
                walletAssets: walletAssets,
                transactions: transactions,
                capabilities: capabilities
            )
        self.capabilities = capabilities
        self.walletAssets = walletAssets
        self.transactions = prepared.transactions
        self.preparationRevision = preparationRevision
        self.onAssetSelected = onAssetSelected

        let snapshot = projection ?? prepared.projectionCache.snapshot(
            assets: walletAssets, directAssets: prepared.baseDirectWalletAssets,
            indexedSelections: prepared.initialSelections, transactions: prepared.transactions,
            networkID: prepared.initialNetworkID,
            eligibleSolanaTokenMints: prepared.eligibleSolanaTokenMints,
            revision: preparationRevision
        )
        receiveAddressesByBlockchain = snapshot.addressesByBlockchain
        walletAssetsByIdentity = snapshot.assetsByIdentity
        baseDirectWalletAssets = snapshot.directAssets
        discoveryIndex = prepared.discoveryIndex
        networkSelectionOrdering =
            prepared.networkSelectionOrdering
        solanaAccounts = prepared.solanaAccounts
        eligibleSolanaTokenMints = prepared.eligibleSolanaTokenMints
        _selectedNetworkID = State(
            initialValue: prepared.initialNetworkID
        )
        let initialSelections = snapshot.initialSelections
        _filteredSelections = State(
            initialValue: initialSelections
        )
        _visibleSelectionCount = State(
            initialValue: AssetListRenderingWindow.initialCount(
                for: initialSelections.count
            )
        )
    }
    var body: some View {
        List {
            Group {
                assetSection
            }
            .walletListRowSurface()
        }
        .walletListAppearance()
        .listStyle(.insetGrouped)
        .background {
            WalletHomeFirstFrameObserver { hasRenderedInitialFrame = true }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .navigationTitle("receive.title")
        .navigationBarTitleDisplayMode(.inline)
        .assetNetworkAppBar(
            isPresented: capabilities.showsNetworkSelector,
            options: networkFilterOptions,
            selectedNetworkID: $selectedNetworkID,
            ordering: networkSelectionOrdering
        )
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("receive.search.prompt")
        )
        .walletTextInputDirection()
        .walletAutomaticSearchToolbarBehavior()
        .task(id: searchRequest) {
            guard hasRenderedInitialFrame else { return }
            await prepareSearchResults()
        }
    }
    @ViewBuilder
    private var assetSection: some View {
        let addressesByBlockchain = receiveAddressesByBlockchain
        Section {
            if filteredSelections.isEmpty {
                WalletSearchEmptyStateView()
            } else {
                ForEach(
                    filteredSelections.prefix(visibleSelectionCount)
                ) { item in
                    switch item {
                    case let .walletAsset(asset):
                        let asset = currentAsset(matching: asset)
                        NavigationLink {
                            Group {
                                SelectedAssetReceiveScreen(
                                    asset: asset,
                                    walletAddress:
                                        asset.receiveAddress ?? walletAddress,
                                    database: database,
                                    solanaAccounts: solanaAccounts
                                )
                                .onAppear {
                                    registerDestinationAppearance(
                                        asset: asset
                                    )
                                }
                            }

                        } label: {
                            UnifiedAssetSelectionRow(
                                name: asset.name,
                                symbol: asset.symbol,
                                logoSource: asset.logoSource,
                                networkLogoSource:
                                    asset.networkLogoSource,
                                familyLogoSource:
                                    asset.familyLogoSource,
                                balance: asset.balance,
                                fiatValue: asset.fiatValue,
                                isBalanceHidden:
                                    applicationSettings
                                        .balancePrivacyEnabled
                            )
                        }
                        .onAppear {
                            rowDidAppear(item.id)
                        }
                    case let .catalog(selection):
                        NavigationLink {
                            Group {
                                if selection.variant.networkID
                                    == SolanaConstants.networkID {
                                    SolanaReceiveSelectionDetailsScreen(
                                        token: selection.token,
                                        variant: selection.variant,
                                        accounts: solanaAccounts
                                    )
                                    .onAppear {
                                        registerDestinationAppearance(
                                            selection: selection
                                        )
                                    }
                                } else {
                                    ReceiveSelectionDetailsScreen(
                                        token: selection.token,
                                        variant: selection.variant,
                                        walletAddress: receiveAddress(
                                            for: selection.variant,
                                            addressesByBlockchain:
                                                addressesByBlockchain
                                        ),
                                        database: database
                                    )
                                    .onAppear {
                                        registerDestinationAppearance(
                                            selection: selection
                                        )
                                    }
                                }
                            }

                        } label: {
                            ReceiveVariantRow(
                                selection: selection,
                                holdingAsset: holdingAsset(
                                    for: selection
                                ),
                                isBalanceHidden:
                                    applicationSettings
                                        .balancePrivacyEnabled
                            )
                        }
                        .onAppear {
                            rowDidAppear(item.id)
                        }
                    }
                }
            }
        } header: {
            Text("receive.assets.section")
        } footer: {
            Text("receive.assets.footer")
        }
    }

    private var networkFilterOptions: [AssetNetworkSelectorOption] {
        capabilities.selectorOptions
    }

    private func receiveAddress(
        for variant: ReceiveTokenVariant,
        addressesByBlockchain:
            [WalletBlockchain: String]
    ) -> String {
        guard let network = variant.network else { return "" }
        if ReceiveAddressResolver.requiresIndependentAddress(
            for: network.blockchain
        ) {
            return addressesByBlockchain[network.blockchain] ?? ""
        }
        return addressesByBlockchain[network.blockchain]
            ?? walletAddress
    }
    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var searchRequest: ReceiveSearchRequest {
        ReceiveSearchRequest(
            searchText: searchText,
            networkID: selectedNetworkID,
            walletAssetCount: walletAssets.count,
            resolvedAssetCount: baseDirectWalletAssets.count,
            transactionCount: transactions.count,
            preparationRevision: preparationRevision,
            eligibleSolanaTokenMints: eligibleSolanaTokenMints
        )
    }
    private var allWalletAssets: [WalletAsset] {
        walletAssets
    }
    private var allDirectWalletAssets: [WalletAsset] {
        baseDirectWalletAssets
    }
    @MainActor
    private func prepareSearchResults() async {
        if !normalizedSearchText.isEmpty {
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
        }
        guard !Task.isCancelled else { return }
        let query = searchText
        let networkID = selectedNetworkID
        let eligibleSolanaTokenMints = eligibleSolanaTokenMints
        let index = discoveryIndex
        let assets = walletAssets
        let directAssets = allDirectWalletAssets
        let transactions = transactions
        let worker = Task.detached(priority: .userInitiated) {
            let indexed = index.selections(networkID: networkID, searchText: query)
            guard !Task.isCancelled else { return [AssetDiscoverySelection]() }
            return WalletAssetLiveSelectionProjection.selections(
                indexedSelections: indexed,
                walletAssets: assets,
                directAssetsByIdentity: Dictionary(
                    directAssets.map { (AssetIdentityKey.canonical($0.id), $0) },
                    uniquingKeysWith: { lhs, rhs in lhs.fiatValue >= rhs.fiatValue ? lhs : rhs }
                ),
                transactions: transactions,
                networkID: networkID,
                searchText: query,
                eligibleSolanaTokenMints: eligibleSolanaTokenMints,
                visibleLimit: networkID == nil
                    ? ReceiveAssetSearchIndex.maximumVisibleResults
                    : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
            )
        }
        let result = await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
        guard !Task.isCancelled else { return }
        apply(
            result,
            source: "search_task"
        )
    }
    @MainActor
    private func apply(
        _ selections: [AssetDiscoverySelection],
        source: String
    ) {
        let currentIDs = filteredSelections.map(\.id)
        let updatedIDs = selections.map(\.id)
        let updatedVisibleCount =
            AssetListRenderingWindow.visibleCountAfterReplacing(
                currentCount: visibleSelectionCount,
                currentIDs: currentIDs,
                updatedIDs: updatedIDs
            )
        AssetListRenderingWindow.replaceBalanceRankedResults(
            currentIDs: currentIDs,
            updatedIDs: updatedIDs,
            reduceMotion: reduceMotion
        ) {
            filteredSelections = selections
            visibleSelectionCount = updatedVisibleCount
        }
    }

    @MainActor
    private func rowDidAppear(_ rowID: String) {
        guard
            let prefetchIndex = AssetListRenderingWindow.prefetchIndex(
                visibleCount: visibleSelectionCount,
                totalCount: filteredSelections.count
            ),
            filteredSelections[prefetchIndex].id == rowID
        else {
            return
        }
        visibleSelectionCount =
            AssetListRenderingWindow.expandedCount(
                currentCount: visibleSelectionCount,
                totalCount: filteredSelections.count
            )
    }

    private func holdingAsset(
        for selection: ReceiveVariantSelection
    ) -> WalletAsset? {
        if let current = walletAssetsByIdentity[
            AssetIdentityKey.canonical(selection.id)
        ] {
            return current
        }
        return nil
    }

    private func currentAsset(
        matching candidate: WalletAsset
    ) -> WalletAsset {
        walletAssetsByIdentity[
            AssetIdentityKey.canonical(candidate.id)
        ] ?? candidate
    }

    private func selectedAsset(
        for selection: ReceiveVariantSelection
    ) -> WalletAsset {
        if let holding = holdingAsset(for: selection) {
            return holding
        }
        return WalletAsset(
            id: selection.variant.assetIdentity,
            name: selection.token.name,
            symbol: selection.token.symbol,
            logoSource: selection.variant.logoSource,
            network: selection.variant.network?.blockchain,
            balance: 0,
            fiatValue: 0,
            decimals: selection.variant.decimals,
            receiveAddress: receiveAddress(
                for: selection.variant,
                addressesByBlockchain:
                    receiveAddressesByBlockchain
            )
        )
    }

    @MainActor
    private func registerDestinationAppearance(
        asset: WalletAsset
    ) {
        onAssetSelected(asset)
    }

    @MainActor
    private func registerDestinationAppearance(
        selection: ReceiveVariantSelection
    ) {
        onAssetSelected(selectedAsset(for: selection))
    }

}

private struct ReceiveSearchRequest: Hashable {
    let searchText: String
    let networkID: String?
    let walletAssetCount: Int
    let resolvedAssetCount: Int
    let transactionCount: Int
    let preparationRevision: UUID
    let eligibleSolanaTokenMints: Set<String>
}
