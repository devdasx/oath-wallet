import GRDB

extension WalletDatabase {
    static func registerSendCustomFeeBudgetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v46_send_custom_fee_total_budget"
        ) { database in
            try database.execute(sql: """
                ALTER TABLE sendCustomFeePreferences
                ADD COLUMN totalBudgetAtomic TEXT
                    CHECK (
                        totalBudgetAtomic IS NULL
                        OR (
                            length(totalBudgetAtomic) > 0
                            AND totalBudgetAtomic NOT GLOB '*[^0-9]*'
                            AND totalBudgetAtomic != '0'
                        )
                    );
                """)
            // TRON's historical custom value was already a direct total fee
            // limit, so it can be migrated losslessly. Rate-based EVM, UTXO,
            // and Solana records cannot recover the user's original total and
            // intentionally remain NULL so they fall back to an automatic fee
            // until the user enters a new local-currency budget.
            try database.execute(sql: """
                UPDATE sendCustomFeePreferences
                SET totalBudgetAtomic = primaryValue
                WHERE model = 'tron_fee_limit';
                """)
        }
    }
}
