import GRDB

extension WalletDatabase {
    static func registerSendRecipientBroadcastMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v44_app_send_recipient_broadcasts") { database in
            // Deliberately no history backfill: provider activity and older
            // outcome-unknown submissions cannot prove an accepted app send.
            // Keep SQLite's rowid so GRDB ValueObservation receives inserts;
            // WITHOUT ROWID tables do not emit SQLite update-hook events.
            try database.execute(sql: """
                CREATE TABLE sendRecipientBroadcasts (
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE CASCADE,
                    normalizedTransactionHash TEXT NOT NULL CHECK (length(normalizedTransactionHash) > 0),
                    recipientIdentity TEXT NOT NULL CHECK (length(recipientIdentity) > 0),
                    recipientAddress TEXT NOT NULL CHECK (length(recipientAddress) > 0),
                    broadcastedAt REAL NOT NULL,
                    PRIMARY KEY(walletID, networkID, normalizedTransactionHash, recipientIdentity)
                );

                CREATE INDEX sendRecipientBroadcasts_by_recipient
                    ON sendRecipientBroadcasts(walletID, networkID, recipientIdentity);
                """)
        }
    }
}
