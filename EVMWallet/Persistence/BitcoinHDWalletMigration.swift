import GRDB

extension WalletDatabase {
    static func registerBitcoinHDWalletMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v52_bitcoin_hd_wallet") { database in
            try database.execute(
                sql: """
                CREATE TABLE bitcoinHDAccounts (
                    walletID TEXT NOT NULL
                        REFERENCES wallets(id) ON DELETE CASCADE,
                    addressType TEXT NOT NULL
                        CHECK (
                            addressType IN (
                                'bip44', 'bip49', 'bip84', 'bip86'
                            )
                        ),
                    accountIndex INTEGER NOT NULL DEFAULT 0
                        CHECK (accountIndex >= 0),
                    accountPath TEXT NOT NULL,
                    extendedPublicKey TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(walletID, addressType, accountIndex),
                    UNIQUE(walletID, accountPath)
                ) WITHOUT ROWID;

                CREATE TABLE bitcoinHDAddresses (
                    walletID TEXT NOT NULL,
                    addressType TEXT NOT NULL,
                    accountIndex INTEGER NOT NULL DEFAULT 0,
                    branch INTEGER NOT NULL CHECK (branch IN (0, 1)),
                    addressIndex INTEGER NOT NULL
                        CHECK (addressIndex >= 0),
                    derivationPath TEXT NOT NULL,
                    address TEXT NOT NULL,
                    publicKey BLOB NOT NULL,
                    scriptPubKey BLOB NOT NULL,
                    scriptHash TEXT NOT NULL,
                    isUsed INTEGER NOT NULL DEFAULT 0
                        CHECK (isUsed IN (0, 1)),
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
                        walletID, addressType, accountIndex,
                        branch, addressIndex
                    ),
                    FOREIGN KEY(walletID, addressType, accountIndex)
                        REFERENCES bitcoinHDAccounts(
                            walletID, addressType, accountIndex
                        ) ON DELETE CASCADE,
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
                CREATE INDEX bitcoinHDAddresses_scan
                    ON bitcoinHDAddresses(
                        walletID, addressType, branch,
                        isUsed, addressIndex
                    );

                CREATE TABLE bitcoinHDPreferences (
                    walletID TEXT PRIMARY KEY NOT NULL
                        REFERENCES wallets(id) ON DELETE CASCADE,
                    receiveAddressType TEXT NOT NULL DEFAULT 'bip84'
                        CHECK (
                            receiveAddressType IN (
                                'bip44', 'bip49', 'bip84', 'bip86'
                            )
                        ),
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;
                """
            )
        }
    }

    static func registerBitcoinHDChangeReservationMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v53_bitcoin_hd_change_reservations"
        ) { database in
            try database.alter(table: "bitcoinHDAddresses") { table in
                table.add(
                    column: "isReserved",
                    .boolean
                ).notNull().defaults(to: false)
            }
            try database.create(
                index: "bitcoinHDAddresses_change_reservations",
                on: "bitcoinHDAddresses",
                columns: [
                    "walletID", "addressType", "branch",
                    "isReserved", "addressIndex"
                ]
            )
        }
    }

    static func registerBitcoinHDKeyCacheMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v54_bitcoin_hd_key_caches"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE bitcoinHDKeyCaches (
                    walletID TEXT NOT NULL
                        REFERENCES wallets(id) ON DELETE CASCADE,
                    addressType TEXT NOT NULL
                        CHECK (
                            addressType IN (
                                'bip44', 'bip49', 'bip84', 'bip86'
                            )
                        ),
                    branch INTEGER NOT NULL CHECK (branch IN (0, 1)),
                    keychainReference TEXT NOT NULL
                        CHECK (length(keychainReference) > 0),
                    highestCachedIndex INTEGER NOT NULL
                        CHECK (highestCachedIndex >= 0),
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(walletID, addressType, branch),
                    UNIQUE(keychainReference)
                ) WITHOUT ROWID;
                """
            )
        }
    }

    static func registerBitcoinHDAddressSelectionMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v56_bitcoin_hd_address_selections"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE bitcoinHDAddressSelections (
                    walletID TEXT NOT NULL,
                    addressType TEXT NOT NULL
                        CHECK (
                            addressType IN (
                                'bip44', 'bip49', 'bip84', 'bip86'
                            )
                        ),
                    accountIndex INTEGER NOT NULL DEFAULT 0
                        CHECK (accountIndex = 0),
                    branch INTEGER NOT NULL CHECK (branch IN (0, 1)),
                    addressIndex INTEGER NOT NULL
                        CHECK (addressIndex >= 0),
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(
                        walletID, addressType, accountIndex, branch
                    ),
                    FOREIGN KEY(
                        walletID, addressType, accountIndex,
                        branch, addressIndex
                    ) REFERENCES bitcoinHDAddresses(
                        walletID, addressType, accountIndex,
                        branch, addressIndex
                    ) ON DELETE CASCADE
                ) WITHOUT ROWID;
                """
            )
        }
    }

    static func registerBitcoinBIP84ReceiveDefaultMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v63_bitcoin_bip84_receive_default"
        ) { database in
            try migrateAutomaticBitcoinBIP44ReceiveDefaults(in: database)
        }
    }

    /// Corrects only the BIP44 value written automatically by the original HD
    /// initializer. An explicit user selection has a later preference
    /// timestamp, so it is intentionally preserved. Wallets without a BIP84
    /// descriptor, including Electrum Standard and uncompressed WIF wallets,
    /// are also left unchanged.
    static func migrateAutomaticBitcoinBIP44ReceiveDefaults(
        in database: Database
    ) throws {
        try database.execute(
            sql: """
            UPDATE bitcoinHDPreferences
            SET receiveAddressType = 'bip84'
            WHERE receiveAddressType = 'bip44'
                AND EXISTS (
                    SELECT 1
                    FROM bitcoinHDAccounts AS nativeSegWit
                    WHERE nativeSegWit.walletID =
                            bitcoinHDPreferences.walletID
                        AND nativeSegWit.addressType = 'bip84'
                        AND nativeSegWit.accountIndex = 0
                )
                AND EXISTS (
                    SELECT 1
                    FROM bitcoinHDAccounts AS initializedAccount
                    WHERE initializedAccount.walletID =
                            bitcoinHDPreferences.walletID
                        AND initializedAccount.createdAt =
                            bitcoinHDPreferences.updatedAt
                );
            """
        )
    }
}
