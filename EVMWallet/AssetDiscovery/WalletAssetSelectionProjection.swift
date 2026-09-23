import Foundation
import os

/// Immutable, revision-scoped asset data. Navigation and search state remain
/// owned by each flow; only the unchanged catalog projection is retained.
struct WalletAssetSelectionProjection: Sendable {
    let assets: [WalletAsset]
    let assetsByIdentity: [String: WalletAsset]
    let directAssets: [WalletAsset]
    let addressesByBlockchain: [WalletBlockchain: String]
    let initialSelections: [AssetDiscoverySelection]
}

final class WalletAssetSelectionProjectionCache: @unchecked Sendable {
    private struct Entry {
        let revision: UUID
        let overlaysBalances: Bool
        let value: WalletAssetSelectionProjection
    }

    private let entries = OSAllocatedUnfairLock(initialState: [Entry]())

    func snapshot(
        assets: [WalletAsset],
        directAssets: [WalletAsset],
        indexedSelections: [AssetDiscoverySelection],
        transactions: [WalletTransaction],
        networkID: String?,
        eligibleSolanaTokenMints: Set<String>,
        revision: UUID,
        balanceAssets: [WalletAsset]? = nil
    ) -> WalletAssetSelectionProjection {
        let overlaysBalances = balanceAssets != nil
        if let cached = entries.withLock({ values in
            values.first {
                $0.revision == revision && $0.overlaysBalances == overlaysBalances
            }?.value
        }) { return cached }
        let currentAssets = balanceAssets.map {
            WalletAssetBalanceSnapshot(assets: $0).projecting(candidates: assets)
        } ?? assets
        let balances = WalletAssetBalanceSnapshot(assets: currentAssets)
        let direct = directAssets.map(balances.resolved)
        let value = WalletAssetSelectionProjection(
            assets: currentAssets,
            assetsByIdentity: Dictionary(
                currentAssets.map { (AssetIdentityKey.canonical($0.id), $0) },
                uniquingKeysWith: AssetDiscoveryRanking.preferredAsset
            ),
            directAssets: direct,
            addressesByBlockchain: ReceiveAddressIndex.make(from: currentAssets),
            initialSelections: WalletAssetLiveSelectionProjection.selections(
                indexedSelections: indexedSelections,
                walletAssets: currentAssets,
                directAssetsByIdentity: Dictionary(
                    direct.map { (AssetIdentityKey.canonical($0.id), $0) },
                    uniquingKeysWith: { lhs, rhs in lhs.fiatValue >= rhs.fiatValue ? lhs : rhs }
                ),
                transactions: transactions,
                networkID: networkID,
                searchText: "",
                eligibleSolanaTokenMints: eligibleSolanaTokenMints,
                visibleLimit: networkID == nil
                    ? ReceiveAssetSearchIndex.maximumVisibleResults
                    : ReceiveAssetCatalog.defaultVisibleTokenLimit + 1
            )
        )
        return entries.withLock { values in
            if let existing = values.first(where: {
                $0.revision == revision && $0.overlaysBalances == overlaysBalances
            }) { return existing.value }
            // Scope is one immutable preparation. Keep only its two most
            // recent revisions, never an unbounded cache of wallet snapshots.
            if values.count == 2 { values.removeFirst() }
            values.append(Entry(revision: revision, overlaysBalances: overlaysBalances, value: value))
            return value
        }
    }
}
