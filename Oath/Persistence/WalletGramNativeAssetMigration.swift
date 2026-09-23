import Foundation
import GRDB

extension WalletDatabase {
    static func registerGramNativeAssetRenameMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v32_ton_native_asset_gram") {
            database in
            let now = Date().timeIntervalSince1970
            let nativeName = WalletLocalization.string(
                TONConstants.nativeAssetNameKey
            )

            try database.execute(
                sql: """
                UPDATE networks
                SET nativeSymbol = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [
                    TONConstants.nativeSymbol,
                    now,
                    TONConstants.networkID
                ]
            )
            try database.execute(
                sql: """
                UPDATE assets
                SET name = ?, symbol = ?, updatedAt = ?,
                    metadataUpdatedAt = ?
                WHERE id = ? AND networkID = ?
                """,
                arguments: [
                    nativeName,
                    TONConstants.nativeSymbol,
                    now,
                    now,
                    TONConstants.nativeAssetID,
                    TONConstants.networkID
                ]
            )
            try database.execute(
                sql: """
                UPDATE transactions
                SET assetSymbol = CASE
                        WHEN assetID = ? THEN ?
                        ELSE assetSymbol
                    END,
                    networkFeeSymbol = CASE
                        WHEN networkFeeSymbol = 'TON' THEN ?
                        ELSE networkFeeSymbol
                    END,
                    updatedAt = ?
                WHERE networkID = ?
                """,
                arguments: [
                    TONConstants.nativeAssetID,
                    TONConstants.nativeSymbol,
                    TONConstants.nativeSymbol,
                    now,
                    TONConstants.networkID
                ]
            )
        }
    }
}
