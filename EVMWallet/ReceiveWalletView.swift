import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct ReceiveAssetFlowView: View {
    let database: WalletDatabase
    let walletAddress: String
    let capabilities: WalletCapabilities
    let walletAssets: [WalletAsset]
    let transactions: [WalletTransaction]
    let preparation: ReceiveAssetSelectionPreparation?
    private let selectionProjection: WalletAssetSelectionProjection
    let preparationRevision: UUID
    let onAssetSelected: (WalletAsset) -> Void

    init(
        database: WalletDatabase,
        walletAddress: String,
        capabilities: WalletCapabilities = .fullWallet,
        walletAssets: [WalletAsset],
        transactions: [WalletTransaction] = [],
        preparation: ReceiveAssetSelectionPreparation? = nil,
        preparationRevision: UUID,
        balanceAssets: [WalletAsset]? = nil,
        balanceRevision: UUID? = nil,
        onAssetSelected: @escaping (WalletAsset) -> Void = { _ in }
    ) {
        self.database = database
        self.walletAddress = walletAddress
        self.capabilities = capabilities
        let prepared = preparation ?? ReceiveAssetSelectionPreparation.make(
            walletAssets: walletAssets, transactions: transactions,
            capabilities: capabilities
        )
        let projection = prepared.projection(
            revision: balanceRevision ?? preparationRevision,
            balanceAssets: balanceAssets
        )
        selectionProjection = projection
        self.walletAssets = projection.assets
        self.transactions = transactions
        self.preparation = prepared
        self.preparationRevision = balanceRevision
            ?? preparationRevision

        self.onAssetSelected = onAssetSelected
    }

    var body: some View {
        ReceiveAssetSelectionView(
            database: database,
            walletAddress: walletAddress,
            capabilities: capabilities,
            walletAssets: walletAssets,
            transactions: transactions,
            preparation: preparation,
            preparationRevision: preparationRevision,
            projection: selectionProjection,
            onAssetSelected: onAssetSelected
        )
    }
}

#Preview("Receive") {
    WalletDatabasePreviewHost { database in
        NavigationStack {
            ReceiveAssetSelectionView(
                database: database,
                walletAddress:
                    "0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
                walletAssets: WalletHomeSnapshot.sample.assets,
                preparationRevision: UUID()
            )
        }
    }
}
