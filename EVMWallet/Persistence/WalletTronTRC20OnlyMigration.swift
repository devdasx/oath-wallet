import GRDB

extension WalletDatabase {
    static func registerTronTRC20OnlyMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v28_tron_trc20_only"
        ) { database in
            try database.execute(
                sql: """
                DELETE FROM transactions
                WHERE networkID = 'tron'
                  AND assetID IN (
                      SELECT id
                      FROM assets
                      WHERE networkID = 'tron'
                        AND id <> 'tron:native'
                        AND assetType <> 'fungibleToken'
                  );

                DELETE FROM accountAssets
                WHERE accountID IN (
                    SELECT id
                    FROM walletAccounts
                    WHERE networkID = 'tron'
                )
                  AND assetID IN (
                      SELECT id
                      FROM assets
                      WHERE networkID = 'tron'
                        AND id <> 'tron:native'
                  )
                  AND (
                      isPinned = 0
                      OR assetID IN (
                          SELECT id
                          FROM assets
                          WHERE networkID = 'tron'
                            AND assetType <> 'fungibleToken'
                      )
                  );

                DELETE FROM assets
                WHERE networkID = 'tron'
                  AND id <> 'tron:native'
                  AND assetType <> 'fungibleToken';
                """
            )
        }
    }
}
