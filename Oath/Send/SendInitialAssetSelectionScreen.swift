import SwiftUI

struct SendInitialAssetSelectionScreen: View {
    let database: WalletDatabase
    let walletAddress: String
    let capabilities: WalletCapabilities
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let preparationRevision: UUID
    let onSelected: (SendAssetChoice) -> Void

    private let walletAssetsByIdentity: [String: WalletAsset]
    private let baseDirectWalletAssets: [WalletAsset]
    private let discoveryIndex: CombinedAssetDiscoveryIndex
    private let networkSelectionOrdering:
        WalletNetworkSelectionOrdering
    private let addressesByBlockchain: [WalletBlockchain: String]
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
        preparation: SendInitialAssetSelectionPreparation? = nil,
        preparationRevision: UUID,
        projection: WalletAssetSelectionProjection? = nil,
        onSelected: @escaping (SendAssetChoice) -> Void
    ) {
        self.database = database
        self.walletAddress = walletAddress
        self.capabilities = capabilities
        let prepared = preparation
            ?? SendInitialAssetSelectionPreparation.make(
                walletAssets: walletAssets,
                transactions: transactions,
                capabilities: capabilities
            )
        self.walletAssets = walletAssets
        self.transactions = prepared.transactions
        self.preparationRevision = preparationRevision
        self.onSelected = onSelected

        let snapshot = projection ?? prepared.projectionCache.snapshot(
            assets: walletAssets, directAssets: prepared.baseDirectWalletAssets,
            indexedSelections: prepared.initialSelections, transactions: prepared.transactions,
            networkID: prepared.initialNetworkID,
            eligibleSolanaTokenMints: prepared.eligibleSolanaTokenMints,
            revision: preparationRevision
        )
        walletAssetsByIdentity = snapshot.assetsByIdentity
        baseDirectWalletAssets = snapshot.directAssets
        discoveryIndex = prepared.discoveryIndex
        networkSelectionOrdering =
            prepared.networkSelectionOrdering
        addressesByBlockchain = snapshot.addressesByBlockchain
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
            WalletHomeFirstFrameObserver {
                hasRenderedInitialFrame = true
            }
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .navigationTitle("send.title")
        .navigationBarTitleDisplayMode(.inline)
        .assetNetworkAppBar(
            isPresented: capabilities.showsNetworkSelector,
            options: capabilities.selectorOptions,
            selectedNetworkID: $selectedNetworkID,
            ordering: networkSelectionOrdering
        )
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("send.search.prompt")
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
        Section {
            if filteredSelections.isEmpty {
                WalletSearchEmptyStateView()
            } else {
                ForEach(
                    filteredSelections.prefix(visibleSelectionCount)
                ) { selection in
                    Button(action: UniHaptic.action {
                        choose(selection)
                    }) {
                        row(for: selection)
                    }
                    .buttonStyle(.automatic)
                    .onAppear {
                        rowDidAppear(selection.id)
                    }
                }
            }
        } header: {
            Text("send.assets.section")
        } footer: {
            Text("send.assets.footer")
        }
    }

    @ViewBuilder
    private func row(
        for selection: AssetDiscoverySelection
    ) -> some View {
        switch selection {
        case let .walletAsset(asset):
            let asset = currentAsset(matching: asset)
            UnifiedAssetSelectionRow(
                name: asset.name,
                symbol: asset.symbol,
                logoSource: asset.logoSource,
                networkLogoSource: asset.networkLogoSource,
                familyLogoSource: asset.familyLogoSource,
                balance: asset.balance,
                fiatValue: asset.fiatValue,
                isBalanceHidden:
                    applicationSettings.balancePrivacyEnabled,
                logoDiagnosticIdentity: asset.id
            )
        case let .catalog(catalogSelection):
            ReceiveVariantRow(
                selection: catalogSelection,
                holdingAsset: holdingAsset(for: catalogSelection),
                isBalanceHidden:
                    applicationSettings.balancePrivacyEnabled
            )
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchRequest: SearchRequest {
        SearchRequest(
            searchText: searchText,
            networkID: selectedNetworkID,
            walletAssetCount: walletAssets.count,
            resolvedAssetCount: baseDirectWalletAssets.count,
            transactionCount: transactions.count,
            preparationRevision: preparationRevision,
            eligibleSolanaTokenMints: eligibleSolanaTokenMints
        )
    }

    private var allDirectWalletAssets: [WalletAsset] {
        baseDirectWalletAssets
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

    private func sourceAddress(
        for blockchain: WalletBlockchain,
        holding: WalletAsset?
    ) -> String? {
        if let address = holding?.receiveAddress, !address.isEmpty {
            return address
        }
        if ReceiveAddressResolver.requiresIndependentAddress(
            for: blockchain
        ) {
            return addressesByBlockchain[blockchain]
        }
        return addressesByBlockchain[blockchain] ?? walletAddress
    }

    private func choice(
        for selection: AssetDiscoverySelection
    ) -> SendAssetChoice? {
        switch selection {
        case let .walletAsset(asset):
            let asset = currentAsset(matching: asset)
            return SendAssetChoiceCatalog.choices(
                from: [asset],
                capabilities: capabilities
            )
            .first
        case let .catalog(catalogSelection):
            guard let network = catalogSelection.variant.network else {
                return nil
            }
            let holding = holdingAsset(for: catalogSelection)
            return SendAssetChoice(
                id: catalogSelection.variant.assetIdentity,
                name: catalogSelection.token.name,
                symbol: catalogSelection.token.symbol,
                networkID: catalogSelection.variant.networkID,
                networkName: network.localizedName,
                blockchain: network.blockchain,
                contractAddress:
                    catalogSelection.variant.contractAddress,
                decimals: catalogSelection.variant.decimals,
                logoSource: catalogSelection.variant.logoSource,
                networkLogoSource: .network(
                    blockchain: network.blockchain
                ),
                balance: holding?.balance ?? 0,
                fiatValue: holding?.fiatValue ?? 0,
                balanceAtomic: holding?.balanceAtomic,
                sourceAddress: sourceAddress(
                    for: network.blockchain,
                    holding: holding
                ),
                isVerified: catalogSelection.variant.isVerified
            )
        }
    }

    private func choose(_ selection: AssetDiscoverySelection) {
        guard let choice = choice(for: selection) else {
            UniHaptic.play(.error)
            return
        }
        UniHaptic.play(.selection)
        onSelected(choice)
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
        let eligibleMints = eligibleSolanaTokenMints
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
                eligibleSolanaTokenMints: eligibleMints,
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

        let currentIDs = filteredSelections.map(\.id)
        let updatedIDs = result.map(\.id)
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
            filteredSelections = result
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

    private struct SearchRequest: Hashable {
        let searchText: String
        let networkID: String?
        let walletAssetCount: Int
        let resolvedAssetCount: Int
        let transactionCount: Int
        let preparationRevision: UUID
        let eligibleSolanaTokenMints: Set<String>
    }
}
