import Foundation
import Testing
@testable import Aperture

struct WalletAssetSelectionProjectionTests {
    @Test func cachedRevisionPreservesRankingAndNewRevisionRefreshesBalances() {
        let original = asset(id: "ethereum:native", balance: 10, address: "0x1111111111111111111111111111111111111111")
        let cache = WalletAssetSelectionProjectionCache()
        let revision = UUID()
        func project(_ revision: UUID, balances: [WalletAsset]) -> WalletAssetSelectionProjection {
            cache.snapshot(
                assets: [original], directAssets: [original],
                indexedSelections: [.walletAsset(original)], transactions: [],
                networkID: nil, eligibleSolanaTokenMints: [],
                revision: revision, balanceAssets: balances
            )
        }
        let first = project(revision, balances: [original])
        let same = project(revision, balances: [original])
        #expect(first.assets == same.assets)
        #expect(first.initialSelections.map(\.canonicalAssetIdentity) == same.initialSelections.map(\.canonicalAssetIdentity))
        let newlyFunded = asset(id: "eth:0x2222222222222222222222222222222222222222", balance: 20)
        let latest = project(UUID(), balances: [newlyFunded])
        #expect(latest.assets.count == 2)
        #expect(latest.assets[0].balance == 0)
        #expect(latest.assets[0].receiveAddress == original.receiveAddress)
        #expect(latest.directAssets[0].balance == 0)
        #expect(latest.assetsByIdentity[AssetIdentityKey.canonical(newlyFunded.id)]?.balance == 20)
        #expect(latest.initialSelections.first?.canonicalAssetIdentity == AssetIdentityKey.canonical(newlyFunded.id))
        #expect(latest.addressesByBlockchain[.ethereum] == original.receiveAddress)
        // Returning to an older retained revision cannot leak newer balances.
        #expect(project(revision, balances: [original]).assets == first.assets)
    }

    @Test func balanceOverlayAndPreparedCatalogNeverShareAnEntry() {
        let original = asset(id: "ethereum:native", balance: 10)
        let cache = WalletAssetSelectionProjectionCache()
        let revision = UUID()
        func project(_ balances: [WalletAsset]?) -> WalletAssetSelectionProjection {
            cache.snapshot(assets: [original], directAssets: [original],
                           indexedSelections: [], transactions: [], networkID: nil,
                           eligibleSolanaTokenMints: [], revision: revision, balanceAssets: balances)
        }
        #expect(project(nil).assets[0].balance == 10)
        #expect(project([]).assets[0].balance == 0)
        #expect(project(nil).assets[0].balance == 10)
    }

    private func asset(id: String, balance: Decimal, address: String? = nil) -> WalletAsset {
        WalletAsset(id: id, name: "Fixture", symbol: "ETH", logoSource: .nativeCoin(blockchain: .ethereum),
                    network: .ethereum, balance: balance, fiatValue: balance,
                    receiveAddress: address)
    }
}
