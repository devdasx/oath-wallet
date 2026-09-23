import Foundation
import Testing
@testable import Aperture

struct WalletSnapshotDatasetPublicationTests {
    @Test
    func balanceProgressPublishesOnlyThePortfolioDataset() {
        #expect(
            WalletSyncProgressEvent.Stage.balancesPersisted
                .publicationScope == .portfolio
        )
    }

    @Test
    func transactionProgressPublishesOnlyTheActivityDataset() {
        #expect(
            WalletSyncProgressEvent.Stage.transactionsPersisted
                .publicationScope == .activity
        )
    }

    @Test
    func legacyCombinedSnapshotProgressStillPublishesBothDatasets() {
        #expect(
            WalletSyncProgressEvent.Stage.snapshotPersisted
                .publicationScope == .portfolioAndActivity
        )
    }

    @Test
    func portfolioReplacementPreservesPublishedActivity() {
        let transaction = makeTransaction(id: "existing-transaction")
        let original = WalletHomeSnapshot(
            totalBalance: 1,
            assets: [makeAsset(id: "existing-asset", fiatValue: 1)],
            transactions: [transaction],
            hasStoredActivity: true
        )
        let replacement = WalletHomePortfolioSnapshotSlice(
            totalBalance: 20,
            assets: [makeAsset(id: "updated-asset", fiatValue: 20)]
        )

        let result = original.replacingPortfolio(replacement)

        #expect(result.totalBalance == 20)
        #expect(result.assets.map(\.id) == ["updated-asset"])
        #expect(result.persistenceTransactions.map(\.id) == [transaction.id])
        #expect(result.hasStoredActivity)
    }

    @Test
    func activityReplacementPreservesPublishedPortfolio() {
        let asset = makeAsset(id: "existing-asset", fiatValue: 20)
        let original = WalletHomeSnapshot(
            totalBalance: 20,
            assets: [asset],
            transactions: [],
            hasStoredActivity: false
        )
        let transaction = makeTransaction(id: "updated-transaction")
        let replacement = WalletHomeActivitySnapshotSlice(
            transactions: [transaction],
            hasStoredActivity: true
        )

        let result = original.replacingActivity(replacement)

        #expect(result.totalBalance == 20)
        #expect(result.assets.map(\.id) == [asset.id])
        #expect(result.persistenceTransactions.map(\.id) == [transaction.id])
        #expect(result.hasStoredActivity)
    }

    private func makeAsset(
        id: String,
        fiatValue: Decimal
    ) -> WalletAsset {
        WalletAsset(
            id: id,
            name: "Ether",
            symbol: "ETH",
            logoSource: .nativeCoin(blockchain: .ethereum),
            network: .ethereum,
            balance: 1,
            fiatValue: fiatValue
        )
    }

    private func makeTransaction(id: String) -> WalletTransaction {
        WalletTransaction(
            id: id,
            kind: .received(assetSymbol: "ETH"),
            detail: "",
            time: "",
            assetLogoSource: .nativeCoin(blockchain: .ethereum),
            assetAmount: 1,
            assetSymbol: "ETH",
            fiatValue: nil,
            status: .confirmed
        )
    }
}
