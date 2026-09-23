import GRDB

extension WalletDatabase {
    static func registerBitcoinSilentPaymentMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v55_bitcoin_silent_payments"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE bitcoinHDPreferences ADD COLUMN
                    usesSilentPayments INTEGER NOT NULL DEFAULT 0
                    CHECK (usesSilentPayments IN (0, 1));

                CREATE TABLE bitcoinSilentPaymentAccounts (
                    walletID TEXT PRIMARY KEY NOT NULL
                        REFERENCES wallets(id) ON DELETE CASCADE,
                    address TEXT NOT NULL UNIQUE
                        CHECK (length(address) > 0),
                    scanPublicKey BLOB NOT NULL
                        CHECK (length(scanPublicKey) = 33),
                    spendPublicKey BLOB NOT NULL
                        CHECK (length(spendPublicKey) = 33),
                    keychainReference TEXT NOT NULL UNIQUE
                        CHECK (length(keychainReference) > 0),
                    birthHeight INTEGER NOT NULL DEFAULT 709632
                        CHECK (birthHeight >= 709632),
                    lastScanHeight INTEGER NOT NULL DEFAULT 709631
                        CHECK (lastScanHeight >= 709631),
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE bitcoinSilentPaymentOutputs (
                    walletID TEXT NOT NULL
                        REFERENCES bitcoinSilentPaymentAccounts(walletID)
                        ON DELETE CASCADE,
                    transactionHash TEXT NOT NULL
                        CHECK (
                            length(transactionHash) = 64
                            AND transactionHash
                                NOT GLOB '*[^0-9a-f]*'
                        ),
                    outputIndex INTEGER NOT NULL
                        CHECK (outputIndex >= 0),
                    valueAtomic TEXT NOT NULL
                        CHECK (
                            length(valueAtomic) > 0
                            AND valueAtomic NOT GLOB '*[^0-9]*'
                        ),
                    scriptPubKey BLOB NOT NULL
                        CHECK (length(scriptPubKey) = 34),
                    outputPublicKey BLOB NOT NULL
                        CHECK (length(outputPublicKey) = 32),
                    keychainReference TEXT NOT NULL UNIQUE
                        CHECK (length(keychainReference) > 0),
                    blockHeight INTEGER,
                    blockTimestamp REAL,
                    isSpent INTEGER NOT NULL DEFAULT 0
                        CHECK (isSpent IN (0, 1)),
                    spentByTransactionHash TEXT
                        CHECK (
                            spentByTransactionHash IS NULL
                            OR (
                                length(spentByTransactionHash) = 64
                                AND spentByTransactionHash
                                    NOT GLOB '*[^0-9a-f]*'
                            )
                        ),
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(walletID, transactionHash, outputIndex),
                    UNIQUE(walletID, scriptPubKey)
                ) WITHOUT ROWID;

                CREATE INDEX bitcoinSilentPaymentOutputs_unspent
                    ON bitcoinSilentPaymentOutputs(
                        walletID, isSpent, blockHeight,
                        transactionHash, outputIndex
                    );
                """
            )
        }
    }

    static func registerBitcoinSilentPaymentBalanceAuthorityMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v67_bitcoin_silent_payment_balance_authority"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE bitcoinSilentPaymentAccounts ADD COLUMN
                    balanceIsAuthoritative INTEGER NOT NULL DEFAULT 0
                    CHECK (balanceIsAuthoritative IN (0, 1));
                """
            )
        }
    }

    static func registerBitcoinSilentPaymentScanProgressMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v68_bitcoin_silent_payment_scan_progress"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE bitcoinSilentPaymentAccounts ADD COLUMN
                    scanTargetHeight INTEGER NOT NULL DEFAULT 709631
                    CHECK (scanTargetHeight >= 709631);

                UPDATE bitcoinSilentPaymentAccounts
                SET scanTargetHeight = MAX(
                    lastScanHeight,
                    birthHeight - 1
                );
                """
            )
        }
    }
}
