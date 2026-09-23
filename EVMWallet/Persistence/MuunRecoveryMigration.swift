import GRDB

extension WalletDatabase {
    static func registerMuunRecoveryMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v64_muun_recovery_wallets") { database in
            try database.execute(
                sql: """
                CREATE TABLE muunRecoveryWallets (
                    walletID TEXT PRIMARY KEY NOT NULL
                        REFERENCES wallets(id) ON DELETE CASCADE,
                    birthdayBlock INTEGER NOT NULL
                        CHECK (birthdayBlock >= 0 AND birthdayBlock <= 65535),
                    recoveryScanCursor INTEGER NOT NULL DEFAULT 0
                        CHECK (recoveryScanCursor >= 0),
                    fullScanCompleted INTEGER NOT NULL DEFAULT 0
                        CHECK (fullScanCompleted IN (0, 1)),
                    nextExternalIndex INTEGER NOT NULL DEFAULT 0
                        CHECK (nextExternalIndex >= 0),
                    nextChangeIndex INTEGER NOT NULL DEFAULT 0
                        CHECK (nextChangeIndex >= 0),
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;

                CREATE TABLE muunRecoveryAddresses (
                    walletID TEXT NOT NULL
                        REFERENCES muunRecoveryWallets(walletID)
                        ON DELETE CASCADE,
                    version INTEGER NOT NULL
                        CHECK (version IN (2, 3, 4, 5)),
                    branch INTEGER NOT NULL
                        CHECK (branch IN (0, 1, 2)),
                    contactIndex INTEGER NOT NULL DEFAULT -1
                        CHECK (
                            (branch = 2 AND contactIndex >= 0)
                            OR (branch IN (0, 1) AND contactIndex = -1)
                        ),
                    addressIndex INTEGER NOT NULL
                        CHECK (addressIndex >= 0),
                    derivationPath TEXT NOT NULL,
                    address TEXT NOT NULL,
                    scriptPubKey BLOB NOT NULL,
                    scriptHash TEXT NOT NULL,
                    isUsed INTEGER NOT NULL DEFAULT 0
                        CHECK (isUsed IN (0, 1)),
                    isReserved INTEGER NOT NULL DEFAULT 0
                        CHECK (isReserved IN (0, 1)),
                    confirmedBalanceAtomic TEXT NOT NULL DEFAULT '0'
                        CHECK (
                            length(confirmedBalanceAtomic) > 0
                            AND confirmedBalanceAtomic
                                NOT GLOB '*[^0-9]*'
                        ),
                    unconfirmedBalanceAtomic TEXT NOT NULL DEFAULT '0',
                    lastCheckedAt REAL,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(
                        walletID, version, branch,
                        contactIndex, addressIndex
                    ),
                    UNIQUE(walletID, address),
                    UNIQUE(walletID, scriptHash),
                    CHECK (
                        (
                            length(unconfirmedBalanceAtomic) > 0
                            AND unconfirmedBalanceAtomic
                                NOT GLOB '*[^0-9]*'
                        )
                        OR (
                            length(unconfirmedBalanceAtomic) > 1
                            AND substr(unconfirmedBalanceAtomic, 1, 1) = '-'
                            AND substr(unconfirmedBalanceAtomic, 2)
                                NOT GLOB '*[^0-9]*'
                        )
                    )
                ) WITHOUT ROWID;

                CREATE INDEX muunRecoveryAddresses_funded
                    ON muunRecoveryAddresses(
                        walletID, isUsed, isReserved,
                        branch, addressIndex, version
                    );
                """
            )
        }
    }
}
