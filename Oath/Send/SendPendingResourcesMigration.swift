import GRDB

extension WalletDatabase {
    static func registerSendPendingResourcesMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v71_send_pending_resources") { database in
            try database.execute(sql: """
                CREATE TABLE sendPendingSubmissions (
                    reservationID TEXT PRIMARY KEY NOT NULL,
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
                    transactionHash TEXT NOT NULL,
                    normalizedTransactionHash TEXT NOT NULL,
                    fromAddress TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    UNIQUE(accountID, normalizedTransactionHash)
                );
                CREATE TABLE sendPendingResources (
                    reservationID TEXT NOT NULL REFERENCES sendPendingSubmissions(reservationID) ON DELETE CASCADE,
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    kind TEXT NOT NULL CHECK(kind IN ('outpoint', 'sequence', 'objectVersion', 'transactionID')),
                    value TEXT NOT NULL CHECK(length(value) > 0),
                    PRIMARY KEY(accountID, kind, value)
                ) WITHOUT ROWID;
                CREATE INDEX sendPendingResources_submission ON sendPendingResources(reservationID);
                """)
        }
    }
}
