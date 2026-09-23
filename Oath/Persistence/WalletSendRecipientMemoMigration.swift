import GRDB

extension WalletDatabase {
    static func registerSendRecipientMemoMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v45_app_send_recipient_memos") { database in
            try database.execute(sql: """
                ALTER TABLE sendRecipientBroadcasts ADD COLUMN networkMemo TEXT;
                ALTER TABLE sendRecipientBroadcasts ADD COLUMN memoRecorded INTEGER NOT NULL DEFAULT 0
                    CHECK (memoRecorded IN (0, 1) AND (memoRecorded = 1 OR networkMemo IS NULL));

                UPDATE sendRecipientBroadcasts SET memoRecorded = 1
                    WHERE networkID NOT IN ('xrp', 'stellar', 'ton', 'solana');

                CREATE INDEX sendRecipientBroadcasts_by_routing
                    ON sendRecipientBroadcasts(walletID, networkID, recipientIdentity, memoRecorded, networkMemo);
                """)
            // Retain every v44 broadcast. On memo-capable chains its old,
            // unrecorded memo is NOT proof that the transaction had no memo.
            // API/cache history is intentionally never used to fill the gap.
        }
    }
}
