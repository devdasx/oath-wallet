import GRDB

extension WalletDatabase {
    static func registerTokenDEXPriceMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v78_token_dex_first_prices") { database in
            // Remove derived valuations only. Preserve all assets, raw balances,
            // transaction records, user notes and native-coin/fee valuations.
            try database.execute(sql: """
                DELETE FROM assetPrices
                WHERE assetID IN (SELECT id FROM assets WHERE assetType <> 'native');
                UPDATE accountAssets SET fiatUSDValue = NULL
                WHERE assetID IN (SELECT id FROM assets WHERE assetType <> 'native');
                UPDATE transactions SET fiatUSDValue = NULL
                WHERE assetID IN (SELECT id FROM assets WHERE assetType <> 'native');
                UPDATE transactionTransfers SET fiatUSDValue = NULL
                WHERE assetID IN (SELECT id FROM assets WHERE assetType <> 'native');
                """)
        }
    }
}
