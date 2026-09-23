import GRDB

extension WalletDatabase {
    static func registerPendingTransactionReconciliationMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v86_pending_transaction_reconciliation") { db in
            try db.execute(sql: """
                ALTER TABLE transactions ADD COLUMN observedStatus TEXT;
                ALTER TABLE transactions ADD COLUMN replacementTransactionHash TEXT;
                CREATE TABLE pendingTransactionEvidence (
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id),
                    transactionHash TEXT NOT NULL,
                    rawTransaction TEXT,
                    nonce INTEGER,
                    firstMissingAt REAL,
                    missingCount INTEGER NOT NULL DEFAULT 0,
                    lastCheckedAt REAL,
                    balanceNeedsRefresh INTEGER NOT NULL DEFAULT 0,
                    balanceInvalidatedAt REAL,
                    PRIMARY KEY(accountID, networkID, transactionHash)
                );
                CREATE TRIGGER transactions_preserve_status_observation
                AFTER UPDATE ON transactions
                WHEN NEW.status IN ('pending', 'canceled') AND NEW.observedStatus IS NULL
                  AND OLD.observedStatus IS NOT NULL
                  AND OLD.transactionHash = NEW.transactionHash
                BEGIN
                    UPDATE transactions SET observedStatus = OLD.observedStatus,
                        replacementTransactionHash = OLD.replacementTransactionHash WHERE id = NEW.id;
                END;
                CREATE TRIGGER transactions_refresh_terminal_balance
                AFTER UPDATE OF status ON transactions
                WHEN OLD.status = 'pending' AND NEW.status IN ('confirmed', 'failed', 'canceled')
                BEGIN
                    INSERT INTO pendingTransactionEvidence(accountID, networkID, transactionHash,
                        balanceNeedsRefresh, balanceInvalidatedAt)
                    VALUES (NEW.accountID, NEW.networkID, NEW.normalizedTransactionHash, 1,
                        (julianday('now') - 2440587.5) * 86400.0)
                    ON CONFLICT(accountID, networkID, transactionHash) DO UPDATE SET
                        balanceNeedsRefresh = 1, balanceInvalidatedAt = excluded.balanceInvalidatedAt;
                END;
                """)
        }
    }

    static func registerSendStatusTrackingMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v77_send_status_tracking") { db in
            // Public transaction evidence only. No signed payload or key material.
            try db.execute(sql: """
                CREATE TABLE sendStatusTracking (
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id),
                    transactionHash TEXT NOT NULL,
                    normalizedTransactionHash TEXT NOT NULL,
                    fromAddress TEXT NOT NULL,
                    toAddress TEXT NOT NULL,
                    submittedAt REAL NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending',
                    PRIMARY KEY(accountID, networkID, normalizedTransactionHash)
                );
                CREATE INDEX transactions_pending_monitor ON transactions(accountID, networkID)
                    WHERE status = 'pending';
                CREATE TRIGGER transactions_preserve_terminal_status
                AFTER UPDATE ON transactions
                WHEN OLD.status IN ('confirmed', 'failed', 'canceled') AND NEW.status = 'pending'
                  AND OLD.accountID = NEW.accountID AND OLD.networkID = NEW.networkID
                  AND OLD.transactionHash = NEW.transactionHash
                BEGIN
                    UPDATE transactions SET status = OLD.status, displayTime = OLD.displayTime,
                        blockNumber = COALESCE(NEW.blockNumber, OLD.blockNumber),
                        blockHash = COALESCE(NEW.blockHash, OLD.blockHash)
                    WHERE id = NEW.id;
                END;
                """)
        }
    }
}
