import Foundation
import GRDB

extension WalletDatabase {
    static func registerSendSpendReservationMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v62_send_spend_reservations"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE sendSpendReservations (
                    accountID TEXT PRIMARY KEY NOT NULL
                        REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    reservationID TEXT NOT NULL UNIQUE,
                    walletID TEXT NOT NULL
                        REFERENCES wallets(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL
                        REFERENCES networks(id) ON DELETE CASCADE,
                    state TEXT NOT NULL
                        CHECK (
                            state IN (
                                'preparing', 'submissionStarted'
                            )
                        ),
                    transactionHash TEXT,
                    normalizedTransactionHash TEXT,
                    fromAddress TEXT,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    CHECK (
                        (
                            state = 'preparing'
                            AND transactionHash IS NULL
                            AND normalizedTransactionHash IS NULL
                            AND fromAddress IS NULL
                        )
                        OR
                        (
                            state = 'submissionStarted'
                            AND length(transactionHash) > 0
                            AND length(normalizedTransactionHash) > 0
                            AND length(fromAddress) > 0
                        )
                    )
                ) WITHOUT ROWID;

                CREATE INDEX sendSpendReservations_transaction
                    ON sendSpendReservations(
                        accountID,
                        networkID,
                        normalizedTransactionHash
                    )
                    WHERE state = 'submissionStarted';
                """
            )
        }
    }

    static func registerPostCoreMigrations(
        on migrator: inout DatabaseMigrator
    ) {
        registerSolanaTokenEligibilityMigration(on: &migrator)
        registerCloudBackupRemoteDurabilityMigration(on: &migrator)
        registerEVMTransactionReconciliationMigration(on: &migrator)
        registerSolanaSpendableBalanceMigration(on: &migrator)
        registerSecureCleanupJournalMigration(on: &migrator)
        registerTronTRC20OnlyMigration(on: &migrator)
        registerRetiredEVMNetworksMigration(on: &migrator)
        registerTokenSafetyCleanupMigration(on: &migrator)
        registerTONMainnetMigration(on: &migrator)
        registerGramNativeAssetRenameMigration(on: &migrator)
        registerSuiMainnetMigration(on: &migrator)
        registerXRPMainnetMigration(on: &migrator)
        registerNEARMainnetMigration(on: &migrator)
        registerAptosMainnetMigration(on: &migrator)
        registerStellarMainnetMigration(on: &migrator)
        registerProviderReliabilityMigration(on: &migrator)
        registerWalletAppearanceMigration(on: &migrator)
        registerCloudBackupIdentityMigration(on: &migrator)
    }

    private static func registerEVMTransactionReconciliationMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v24_evm_transaction_reconciliation"
        ) { database in
            try repairHistoricalEVMTransactionDuplicates(
                database: database
            )
            try database.execute(
                sql: """
                CREATE INDEX transactions_evm_reconciliation_lookup
                    ON transactions(
                        accountID,
                        networkID,
                        normalizedTransactionHash,
                        assetID
                    );

                CREATE UNIQUE INDEX transactions_local_send_identity
                    ON transactions(
                        accountID,
                        networkID,
                        normalizedTransactionHash,
                        COALESCE(assetID, '')
                    )
                    WHERE id LIKE 'send:%';
                """
            )
        }
    }

    private static func registerSolanaSpendableBalanceMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v25_solana_spendable_balance"
        ) { database in
            _ = try repairHistoricalSolanaAggregatedBalances(
                database: database
            )
        }
    }

    static func repairHistoricalSolanaAggregatedBalances(
        database: Database,
        now: Double = Date().timeIntervalSince1970
    ) throws -> Int {
        try database.execute(
            sql: """
            UPDATE accountAssets
            SET balance = '0',
                balanceAtomic = CASE
                    WHEN balanceAtomic IS NULL THEN NULL
                    ELSE '0'
                END,
                fiatUSDValue = CASE
                    WHEN fiatUSDValue IS NULL THEN NULL
                    ELSE '0'
                END,
                updatedAt = ?
            WHERE accountID IN (
                SELECT id
                FROM walletAccounts
                WHERE networkID = ?
            )
            """,
            arguments: [now, SolanaConstants.networkID]
        )
        return database.changesCount
    }

    static func registerRetiredStorageCleanup(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v41_retired_cross_app_storage"
        ) { database in
            try database.execute(
                sql: """
                DROP TABLE IF EXISTS legacyWalletImports;
                DROP TABLE IF EXISTS legacyWalletMigrationRuns;

                DELETE FROM grdb_migrations
                WHERE identifier IN (
                    'v34_legacy_wallet_import_journal',
                    'v38_legacy_wallet_import_completion'
                );
                """
            )
        }
    }
}
