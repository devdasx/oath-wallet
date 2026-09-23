import Foundation

struct SendInitialAssetSelectionPreparation: Sendable {
    let projectionCache: WalletAssetSelectionProjectionCache
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let walletAssetsByIdentity: [String: WalletAsset]
    let baseDirectWalletAssets: [WalletAsset]
    let discoveryIndex: CombinedAssetDiscoveryIndex
    let networkSelectionOrdering: WalletNetworkSelectionOrdering
    let initialNetworkID: String?
    let initialSelections: [AssetDiscoverySelection]
    let eligibleSolanaTokenMints: Set<String>

    init(matching receive: ReceiveAssetSelectionPreparation) {
        projectionCache = receive.projectionCache
        walletAssets = receive.walletAssets
        transactions = receive.transactions
        walletAssetsByIdentity = receive.walletAssetsByIdentity
        baseDirectWalletAssets = receive.baseDirectWalletAssets
        discoveryIndex = receive.discoveryIndex
        networkSelectionOrdering = receive.networkSelectionOrdering
        initialNetworkID = receive.initialNetworkID
        initialSelections = receive.initialSelections
        eligibleSolanaTokenMints = receive.eligibleSolanaTokenMints
    }

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
        capabilities: WalletCapabilities
    ) -> SendInitialAssetSelectionPreparation {
        SendInitialAssetSelectionPreparation(
            matching: ReceiveAssetSelectionPreparation.make(
                walletAssets: walletAssets,
                transactions: transactions,
                capabilities: capabilities
            )
        )
    }
}
