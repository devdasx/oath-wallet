import Foundation

struct ReceiveAssetSelectionPreparation: Sendable {
    let projectionCache = WalletAssetSelectionProjectionCache()
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let walletAssetsByIdentity: [String: WalletAsset]
    let baseDirectWalletAssets: [WalletAsset]
    let discoveryIndex: CombinedAssetDiscoveryIndex
    let networkSelectionOrdering: WalletNetworkSelectionOrdering
    let initialNetworkID: String?
    let initialSelections: [AssetDiscoverySelection]
    let solanaAccounts: SolanaAccountSet?
    let eligibleSolanaTokenMints: Set<String>

    func projection(revision: UUID, balanceAssets: [WalletAsset]? = nil) -> WalletAssetSelectionProjection {
        projectionCache.snapshot(
            assets: walletAssets, directAssets: baseDirectWalletAssets,
            indexedSelections: initialSelections, transactions: transactions,
            networkID: initialNetworkID, eligibleSolanaTokenMints: eligibleSolanaTokenMints,
            revision: revision, balanceAssets: balanceAssets
        )
    }

    static func make(
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        capabilities: WalletCapabilities,
        accountAddresses: WalletAccountAddressIndex = .empty,
        eligibleSolanaTokenMints: Set<String> = []
    ) -> ReceiveAssetSelectionPreparation {
        let scopedAssets = capabilities.filteredAssets(walletAssets).filter {
            !$0.isSpam
        }
        let scopedTransactions = capabilities.filteredTransactions(
            transactions
        )
        let assetsByIdentity = Dictionary(
            scopedAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.fiatValue >= rhs.fiatValue ? lhs : rhs
            }
        )
        let allDirectAssets = directAssets(from: scopedAssets)
        let availableDirectAssets = allDirectAssets.filter(
            ReceiveDirectAccountResolutionPlan.hasValidatedAddress
        )
        let index = CombinedAssetDiscoveryIndex(
            walletAssets: scopedAssets,
            directAssets: allDirectAssets,
            transactions: scopedTransactions,
            holdingsByIdentity: assetsByIdentity
        )
        let ordering = WalletNetworkSelectionOrdering(
            walletAssets: scopedAssets,
            transactions: scopedTransactions
        )
        let initialNetworkID = capabilities.showsNetworkSelector
            ? nil
            : capabilities.privateKeyNetwork?.networkID
        let availableDirectAssetsByID = Dictionary(
            availableDirectAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.fiatValue >= rhs.fiatValue ? lhs : rhs
            }
        )
        let initialSelections = index.selections(
            networkID: initialNetworkID,
            searchText: ""
        )
        .compactMap { selection in
            switch selection {
            case let .walletAsset(asset):
                return availableDirectAssetsByID[
                    AssetIdentityKey.canonical(asset.id)
                ].map(AssetDiscoverySelection.walletAsset)
            case let .catalog(catalogSelection):
                return isInitiallyEligibleCatalogSelection(
                    catalogSelection,
                    eligibleSolanaTokenMints:
                        eligibleSolanaTokenMints
                ) ? selection : nil
            }
        }
        .prefix(ReceiveAssetSearchIndex.maximumVisibleResults)
        .map { $0 }

        return ReceiveAssetSelectionPreparation(
            walletAssets: scopedAssets,
            transactions: scopedTransactions,
            walletAssetsByIdentity: assetsByIdentity,
            baseDirectWalletAssets: availableDirectAssets,
            discoveryIndex: index,
            networkSelectionOrdering: ordering,
            initialNetworkID: initialNetworkID,
            initialSelections: initialSelections,
            solanaAccounts: accountAddresses.solanaAccounts,
            eligibleSolanaTokenMints: eligibleSolanaTokenMints
        )
    }

    static func makeIndexed(
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction],
        capabilities: WalletCapabilities,
        accountAddresses: WalletAccountAddressIndex = .empty,
        eligibleSolanaTokenMints: Set<String> = []
    ) async -> ReceiveAssetSelectionPreparation {
        let scopedAssets = capabilities.filteredAssets(walletAssets).filter {
            !$0.isSpam
        }
        let scopedTransactions = capabilities.filteredTransactions(
            transactions
        )
        let assetsByIdentity = Dictionary(
            scopedAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.fiatValue >= rhs.fiatValue ? lhs : rhs
            }
        )
        let allDirectAssets = directAssets(from: scopedAssets)
        let availableDirectAssets = allDirectAssets.filter(
            ReceiveDirectAccountResolutionPlan.hasValidatedAddress
        )
        async let indexTask = CombinedAssetDiscoveryIndex.make(
            walletAssets: scopedAssets,
            directAssets: allDirectAssets,
            transactions: scopedTransactions,
            holdingsByIdentity: assetsByIdentity
        )
        async let orderingTask = makeNetworkOrdering(
            assets: scopedAssets,
            transactions: scopedTransactions
        )
        let (index, ordering) = await (indexTask, orderingTask)
        return finish(
            scopedAssets: scopedAssets,
            scopedTransactions: scopedTransactions,
            assetsByIdentity: assetsByIdentity,
            availableDirectAssets: availableDirectAssets,
            index: index,
            ordering: ordering,
            capabilities: capabilities,
            solanaAccounts: accountAddresses.solanaAccounts,
            eligibleSolanaTokenMints: eligibleSolanaTokenMints
        )
    }

    private static func directAssets(
        from scopedAssets: [WalletAsset]
    ) -> [WalletAsset] {
        scopedAssets.filter { asset in
            guard let network = asset.network else { return false }
            if BitcoinFamilyChain.allCases.map(\.blockchain)
                .contains(network) || network == .tron || network == .ton {
                return true
            }
            if let evmNetwork = ReceiveNetworkCatalog.network(
                for: network
            ), evmNetwork.chainID > 0 {
                let isNative = AssetIdentityKey.canonical(asset.id)
                    == AssetIdentityKey.make(
                        networkID: evmNetwork.id,
                        contractAddress: nil
                    )
                return isNative
                    || asset.isPinned
                    || !asset.isVerified
                    || ReceiveAssetCatalog.selection(
                        assetIdentity: asset.id
                    ) == nil
            }
            if network == .sui || network == .aptos
                || network == .near || network == .stellar
                || network == .xrp {
                if let networkID = ReceiveNetworkCatalog.network(
                    for: network
                )?.id,
                   AssetIdentityKey.canonical(asset.id)
                    == AssetIdentityKey.make(
                        networkID: networkID,
                        contractAddress: nil
                    ) {
                    return true
                }
                return ReceiveAssetCatalog.selection(
                    assetIdentity: asset.id
                ) == nil
            }
            if network == .solana,
               let networkID = ReceiveNetworkCatalog.network(
                    for: network
               )?.id,
               AssetIdentityKey.canonical(asset.id)
                    == AssetIdentityKey.make(
                        networkID: networkID,
                        contractAddress: nil
                    ) {
                return true
            }
            return network == .solana
                && (
                    asset.requiresExplicitVisibility
                        || ReceiveAssetCatalog.selection(
                            assetIdentity: asset.id
                        ) == nil
                )
        }
    }

    private static func makeNetworkOrdering(
        assets: [WalletAsset],
        transactions: [WalletTransaction]
    ) async -> WalletNetworkSelectionOrdering {
        WalletNetworkSelectionOrdering(
            walletAssets: assets,
            transactions: transactions
        )
    }

    private static func finish(
        scopedAssets: [WalletAsset],
        scopedTransactions: [WalletTransaction],
        assetsByIdentity: [String: WalletAsset],
        availableDirectAssets: [WalletAsset],
        index: CombinedAssetDiscoveryIndex,
        ordering: WalletNetworkSelectionOrdering,
        capabilities: WalletCapabilities,
        solanaAccounts: SolanaAccountSet?,
        eligibleSolanaTokenMints: Set<String>
    ) -> ReceiveAssetSelectionPreparation {
        let initialNetworkID = capabilities.showsNetworkSelector
            ? nil
            : capabilities.privateKeyNetwork?.networkID
        let availableDirectAssetsByID = Dictionary(
            availableDirectAssets.map {
                (AssetIdentityKey.canonical($0.id), $0)
            },
            uniquingKeysWith: { lhs, rhs in
                lhs.fiatValue >= rhs.fiatValue ? lhs : rhs
            }
        )
        let initialSelections = index.selections(
            networkID: initialNetworkID,
            searchText: ""
        )
        .compactMap { selection in
            switch selection {
            case let .walletAsset(asset):
                return availableDirectAssetsByID[
                    AssetIdentityKey.canonical(asset.id)
                ].map(AssetDiscoverySelection.walletAsset)
            case let .catalog(catalogSelection):
                return isInitiallyEligibleCatalogSelection(
                    catalogSelection,
                    eligibleSolanaTokenMints:
                        eligibleSolanaTokenMints
                ) ? selection : nil
            }
        }
        .prefix(ReceiveAssetSearchIndex.maximumVisibleResults)
        .map { $0 }
        return ReceiveAssetSelectionPreparation(
            walletAssets: scopedAssets,
            transactions: scopedTransactions,
            walletAssetsByIdentity: assetsByIdentity,
            baseDirectWalletAssets: availableDirectAssets,
            discoveryIndex: index,
            networkSelectionOrdering: ordering,
            initialNetworkID: initialNetworkID,
            initialSelections: initialSelections,
            solanaAccounts: solanaAccounts,
            eligibleSolanaTokenMints: eligibleSolanaTokenMints
        )
    }

    private static func isInitiallyEligibleCatalogSelection(
        _ selection: ReceiveVariantSelection,
        eligibleSolanaTokenMints: Set<String>
    ) -> Bool {
        guard selection.variant.networkID == SolanaConstants.networkID,
              let mint = selection.variant.contractAddress else {
            return true
        }
        return eligibleSolanaTokenMints.contains(mint)
    }
}

struct ReceiveDirectAccountResolutionPlan: Equatable, Sendable {
    let bitcoinFamily: Bool
    let tron: Bool
    let solana: Bool
    let ton: Bool
    let sui: Bool
    let xrp: Bool
    let near: Bool
    let aptos: Bool
    let stellar: Bool

    init(
        capabilities: WalletCapabilities,
        availableAssets: [WalletAsset]
    ) {
        func requiresResolution(
            _ blockchain: WalletBlockchain
        ) -> Bool {
            capabilities.permits(blockchain: blockchain)
                && !availableAssets.contains {
                    $0.network == blockchain
                        && Self.hasValidatedAddress($0)
                }
        }

        bitcoinFamily = BitcoinFamilyChain.allCases.contains {
            requiresResolution($0.blockchain)
        }
        tron = requiresResolution(.tron)
        solana = requiresResolution(.solana)
        ton = requiresResolution(.ton)
        sui = requiresResolution(.sui)
        xrp = requiresResolution(.xrp)
        near = requiresResolution(.near)
        aptos = requiresResolution(.aptos)
        stellar = requiresResolution(.stellar)
    }

    static func hasValidatedAddress(_ asset: WalletAsset) -> Bool {
        guard let blockchain = asset.network else { return false }
        if let network = ReceiveNetworkCatalog.network(
            for: blockchain
        ), network.chainID > 0,
           let address = asset.receiveAddress {
            return SendAddressValidator.isValidEVMAddress(address)
        }
        return ReceiveAddressResolver.validatedIndependentAddress(
            asset.receiveAddress,
            for: blockchain
        ) != nil
    }
}

enum ReceiveAddressIndex {
    static func make(
        from assets: [WalletAsset]
    ) -> [WalletBlockchain: String] {
        var result: [WalletBlockchain: String] = [:]
        for asset in assets {
            guard
                let blockchain = asset.network,
                result[blockchain] == nil,
                let address = asset.receiveAddress,
                !address.isEmpty
            else {
                continue
            }
            result[blockchain] = address
        }
        return result
    }
}
