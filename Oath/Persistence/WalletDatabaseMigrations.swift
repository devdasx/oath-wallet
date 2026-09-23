import Foundation
import GRDB
extension WalletDatabase {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_wallet_core") { database in
            try database.execute(
                sql: """
                CREATE TABLE profiles (
                    id TEXT PRIMARY KEY NOT NULL,
                    displayName TEXT,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    lastActiveAt REAL NOT NULL
                );

                CREATE TABLE wallets (
                    id TEXT PRIMARY KEY NOT NULL,
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('created', 'importedRecoveryPhrase', 'importedPrivateKey', 'watchOnly', 'hardware')),
                    secretKeyReference TEXT,
                    isSelected INTEGER NOT NULL DEFAULT 0,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    lastOpenedAt REAL,
                    archivedAt REAL
                );
                CREATE UNIQUE INDEX wallets_one_selected_per_profile
                    ON wallets(profileID) WHERE isSelected = 1 AND archivedAt IS NULL;
                CREATE INDEX wallets_profile_sort
                    ON wallets(profileID, archivedAt, sortOrder);

                CREATE TABLE networks (
                    id TEXT PRIMARY KEY NOT NULL,
                    chainID INTEGER NOT NULL UNIQUE,
                    nameKey TEXT NOT NULL,
                    nativeSymbol TEXT NOT NULL,
                    trustWalletBlockchain TEXT NOT NULL,
                    rpcProviderIdentifier TEXT NOT NULL UNIQUE,
                    isMainnet INTEGER NOT NULL DEFAULT 1 CHECK (isMainnet = 1),
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    sortOrder INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                );

                CREATE TABLE walletAccounts (
                    id TEXT PRIMARY KEY NOT NULL,
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE RESTRICT,
                    address TEXT NOT NULL,
                    normalizedAddress TEXT NOT NULL,
                    label TEXT,
                    derivationPath TEXT,
                    accountIndex INTEGER,
                    publicKey TEXT,
                    isWatchOnly INTEGER NOT NULL DEFAULT 0,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    lastSyncedAt REAL,
                    UNIQUE(walletID, networkID, normalizedAddress)
                );
                CREATE INDEX walletAccounts_address
                    ON walletAccounts(normalizedAddress, networkID);
                CREATE INDEX walletAccounts_wallet
                    ON walletAccounts(walletID, isEnabled);

                CREATE TABLE assets (
                    id TEXT PRIMARY KEY NOT NULL,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE RESTRICT,
                    assetType TEXT NOT NULL CHECK (assetType IN ('native', 'fungibleToken', 'nonFungibleToken', 'semiFungibleToken')),
                    contractAddress TEXT NOT NULL DEFAULT '',
                    normalizedContractAddress TEXT NOT NULL DEFAULT '',
                    name TEXT NOT NULL,
                    symbol TEXT NOT NULL,
                    decimals INTEGER,
                    trustWalletBlockchain TEXT,
                    trustWalletContractAddress TEXT,
                    isVerified INTEGER NOT NULL DEFAULT 0,
                    isSpam INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    metadataUpdatedAt REAL,
                    UNIQUE(networkID, normalizedContractAddress)
                );
                CREATE INDEX assets_symbol ON assets(symbol COLLATE NOCASE);
                CREATE INDEX assets_name ON assets(name COLLATE NOCASE);
                CREATE INDEX assets_network_verified
                    ON assets(networkID, isSpam, isVerified);

                CREATE TABLE accountAssets (
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    assetID TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    balance TEXT NOT NULL DEFAULT '0',
                    balanceAtomic TEXT,
                    fiatUSDValue TEXT,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    isPinned INTEGER NOT NULL DEFAULT 0,
                    isHidden INTEGER NOT NULL DEFAULT 0,
                    sortOrder INTEGER,
                    firstSeenAt REAL NOT NULL,
                    lastSeenAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(accountID, assetID)
                ) WITHOUT ROWID;
                CREATE INDEX accountAssets_visible
                    ON accountAssets(accountID, isEnabled, isHidden, fiatUSDValue);

                CREATE TABLE assetPrices (
                    assetID TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    quoteCurrency TEXT NOT NULL,
                    price TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    observedAt REAL NOT NULL,
                    expiresAt REAL,
                    PRIMARY KEY(assetID, quoteCurrency, provider, observedAt)
                ) WITHOUT ROWID;
                CREATE INDEX assetPrices_latest
                    ON assetPrices(assetID, quoteCurrency, observedAt DESC);

                CREATE TABLE marketSnapshots (
                    assetID TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    quoteCurrency TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    observedAt REAL NOT NULL,
                    marketCap TEXT,
                    fullyDilutedValue TEXT,
                    volume24Hours TEXT,
                    change24HoursPercent TEXT,
                    high24Hours TEXT,
                    low24Hours TEXT,
                    circulatingSupply TEXT,
                    totalSupply TEXT,
                    maximumSupply TEXT,
                    marketRank INTEGER,
                    PRIMARY KEY(assetID, quoteCurrency, provider, observedAt)
                ) WITHOUT ROWID;
                CREATE INDEX marketSnapshots_latest
                    ON marketSnapshots(assetID, quoteCurrency, observedAt DESC);

                CREATE TABLE transactions (
                    id TEXT PRIMARY KEY NOT NULL,
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE RESTRICT,
                    transactionHash TEXT NOT NULL,
                    normalizedTransactionHash TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('received', 'sent', 'swapped')),
                    status TEXT NOT NULL CHECK (status IN ('pending', 'confirmed', 'canceled', 'failed')),
                    direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing', 'self', 'unknown')),
                    fromAddress TEXT,
                    toAddress TEXT,
                    counterpartyAddress TEXT,
                    blockNumber INTEGER,
                    blockHash TEXT,
                    transactionIndex INTEGER,
                    nonce INTEGER,
                    transactionType INTEGER,
                    timestamp REAL,
                    assetID TEXT REFERENCES assets(id) ON DELETE SET NULL,
                    assetSymbol TEXT NOT NULL,
                    secondaryAssetSymbol TEXT,
                    assetAmount TEXT NOT NULL,
                    fiatUSDValue TEXT,
                    networkFee TEXT,
                    networkFeeFiatUSDValue TEXT,
                    networkFeeSymbol TEXT,
                    gasPriceGwei TEXT,
                    gasLimit INTEGER,
                    gasUsed INTEGER,
                    inputData TEXT,
                    methodName TEXT,
                    displayDetail TEXT NOT NULL DEFAULT '',
                    displayTime TEXT NOT NULL DEFAULT '',
                    firstSeenAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    UNIQUE(accountID, networkID, normalizedTransactionHash, id)
                );
                CREATE INDEX transactions_activity
                    ON transactions(accountID, timestamp DESC, blockNumber DESC);
                CREATE INDEX transactions_hash
                    ON transactions(networkID, normalizedTransactionHash);
                CREATE INDEX transactions_status
                    ON transactions(accountID, status, timestamp DESC);
                CREATE INDEX transactions_asset
                    ON transactions(accountID, assetID, timestamp DESC);

                CREATE TABLE transactionTransfers (
                    id TEXT PRIMARY KEY NOT NULL,
                    transactionID TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                    logIndex INTEGER,
                    assetID TEXT REFERENCES assets(id) ON DELETE SET NULL,
                    fromAddress TEXT,
                    toAddress TEXT,
                    direction TEXT NOT NULL CHECK (direction IN ('incoming', 'outgoing', 'self', 'unknown')),
                    amount TEXT NOT NULL,
                    amountAtomic TEXT,
                    fiatUSDValue TEXT,
                    tokenName TEXT,
                    tokenSymbol TEXT NOT NULL,
                    tokenDecimals INTEGER
                );
                CREATE INDEX transactionTransfers_transaction
                    ON transactionTransfers(transactionID, logIndex);
                CREATE INDEX transactionTransfers_asset
                    ON transactionTransfers(assetID, transactionID);

                CREATE TABLE nftCollections (
                    id TEXT PRIMARY KEY NOT NULL,
                    networkID TEXT NOT NULL REFERENCES networks(id) ON DELETE RESTRICT,
                    contractAddress TEXT NOT NULL,
                    normalizedContractAddress TEXT NOT NULL,
                    name TEXT NOT NULL,
                    symbol TEXT,
                    standard TEXT NOT NULL CHECK (standard IN ('erc721', 'erc1155')),
                    imageURL TEXT,
                    isVerified INTEGER NOT NULL DEFAULT 0,
                    isSpam INTEGER NOT NULL DEFAULT 0,
                    updatedAt REAL NOT NULL,
                    UNIQUE(networkID, normalizedContractAddress)
                );

                CREATE TABLE nftItems (
                    id TEXT PRIMARY KEY NOT NULL,
                    collectionID TEXT NOT NULL REFERENCES nftCollections(id) ON DELETE CASCADE,
                    tokenID TEXT NOT NULL,
                    name TEXT,
                    description TEXT,
                    imageURL TEXT,
                    animationURL TEXT,
                    metadataURL TEXT,
                    metadataJSON BLOB,
                    updatedAt REAL NOT NULL,
                    UNIQUE(collectionID, tokenID)
                );

                CREATE TABLE accountNFTHoldings (
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    nftItemID TEXT NOT NULL REFERENCES nftItems(id) ON DELETE CASCADE,
                    quantity TEXT NOT NULL DEFAULT '1',
                    isHidden INTEGER NOT NULL DEFAULT 0,
                    lastSeenAt REAL NOT NULL,
                    PRIMARY KEY(accountID, nftItemID)
                ) WITHOUT ROWID;

                CREATE TABLE contacts (
                    id TEXT PRIMARY KEY NOT NULL,
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    note TEXT,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                );
                CREATE INDEX contacts_name ON contacts(profileID, name COLLATE NOCASE);

                CREATE TABLE contactAddresses (
                    id TEXT PRIMARY KEY NOT NULL,
                    contactID TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
                    networkID TEXT REFERENCES networks(id) ON DELETE RESTRICT,
                    address TEXT NOT NULL,
                    normalizedAddress TEXT NOT NULL,
                    label TEXT,
                    isFavorite INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    UNIQUE(contactID, networkID, normalizedAddress)
                );
                CREATE INDEX contactAddresses_lookup
                    ON contactAddresses(normalizedAddress, networkID);

                CREATE TABLE connectedDApps (
                    id TEXT PRIMARY KEY NOT NULL,
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    origin TEXT NOT NULL,
                    name TEXT NOT NULL,
                    iconURL TEXT,
                    sessionTopic TEXT,
                    createdAt REAL NOT NULL,
                    lastUsedAt REAL NOT NULL,
                    expiresAt REAL,
                    UNIQUE(profileID, origin, sessionTopic)
                );

                CREATE TABLE dappPermissions (
                    dappID TEXT NOT NULL REFERENCES connectedDApps(id) ON DELETE CASCADE,
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    method TEXT NOT NULL,
                    chainID INTEGER NOT NULL,
                    grantedAt REAL NOT NULL,
                    PRIMARY KEY(dappID, accountID, method, chainID)
                ) WITHOUT ROWID;

                CREATE TABLE priceAlerts (
                    id TEXT PRIMARY KEY NOT NULL,
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    assetID TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                    quoteCurrency TEXT NOT NULL,
                    comparison TEXT NOT NULL CHECK (comparison IN ('above', 'below')),
                    threshold TEXT NOT NULL,
                    isEnabled INTEGER NOT NULL DEFAULT 1,
                    createdAt REAL NOT NULL,
                    lastTriggeredAt REAL
                );
                CREATE INDEX priceAlerts_enabled
                    ON priceAlerts(profileID, isEnabled, assetID);

                CREATE TABLE notifications (
                    id TEXT PRIMARY KEY NOT NULL,
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    category TEXT NOT NULL,
                    titleKey TEXT NOT NULL,
                    bodyKey TEXT NOT NULL,
                    argumentsJSON BLOB,
                    relatedTransactionID TEXT REFERENCES transactions(id) ON DELETE SET NULL,
                    createdAt REAL NOT NULL,
                    readAt REAL,
                    deliveredAt REAL
                );
                CREATE INDEX notifications_inbox
                    ON notifications(profileID, readAt, createdAt DESC);

                CREATE TABLE userSettings (
                    profileID TEXT PRIMARY KEY NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    appearance TEXT NOT NULL DEFAULT 'system',
                    languageIdentifier TEXT NOT NULL DEFAULT 'en',
                    currencyCode TEXT NOT NULL DEFAULT 'USD',
                    currencyRatePerUSD TEXT NOT NULL DEFAULT '1',
                    balancePrivacyEnabled INTEGER NOT NULL DEFAULT 0,
                    appLockEnabled INTEGER NOT NULL DEFAULT 0,
                    biometricEnabled INTEGER NOT NULL DEFAULT 0,
                    autoLockSeconds INTEGER,
                    notificationsEnabled INTEGER NOT NULL DEFAULT 0,
                    updateNotificationsEnabled INTEGER NOT NULL DEFAULT 0,
                    priceNotificationsEnabled INTEGER NOT NULL DEFAULT 0,
                    transferNotificationsEnabled INTEGER NOT NULL DEFAULT 0,
                    analyticsEnabled INTEGER NOT NULL DEFAULT 0,
                    updatedAt REAL NOT NULL
                );

                CREATE TABLE preferences (
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    key TEXT NOT NULL,
                    valueType TEXT NOT NULL CHECK (valueType IN ('string', 'bool', 'integer', 'double', 'data')),
                    value TEXT NOT NULL,
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(profileID, key)
                ) WITHOUT ROWID;

                CREATE TABLE fxRates (
                    baseCurrency TEXT NOT NULL,
                    quoteCurrency TEXT NOT NULL,
                    rate TEXT NOT NULL,
                    englishName TEXT NOT NULL,
                    symbol TEXT NOT NULL,
                    effectiveDate TEXT NOT NULL,
                    provider TEXT NOT NULL,
                    fetchedAt REAL NOT NULL,
                    PRIMARY KEY(baseCurrency, quoteCurrency, effectiveDate, provider)
                ) WITHOUT ROWID;
                CREATE INDEX fxRates_latest
                    ON fxRates(baseCurrency, fetchedAt DESC, quoteCurrency);

                CREATE TABLE syncStates (
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    resource TEXT NOT NULL,
                    cursor TEXT,
                    lastAttemptAt REAL,
                    lastSuccessAt REAL,
                    nextAllowedAt REAL,
                    consecutiveFailureCount INTEGER NOT NULL DEFAULT 0,
                    lastErrorCode TEXT,
                    PRIMARY KEY(accountID, resource)
                ) WITHOUT ROWID;

                CREATE TABLE apiCache (
                    cacheKey TEXT PRIMARY KEY NOT NULL,
                    provider TEXT NOT NULL,
                    endpoint TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    createdAt REAL NOT NULL,
                    expiresAt REAL NOT NULL,
                    etag TEXT,
                    lastModified TEXT
                );
                CREATE INDEX apiCache_expiration ON apiCache(expiresAt);

                CREATE TABLE pendingOperations (
                    id TEXT PRIMARY KEY NOT NULL,
                    accountID TEXT NOT NULL REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    operationType TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('draft', 'awaitingSignature', 'submitted', 'completed', 'failed', 'canceled')),
                    payload BLOB NOT NULL,
                    idempotencyKey TEXT NOT NULL UNIQUE,
                    retryCount INTEGER NOT NULL DEFAULT 0,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    nextRetryAt REAL,
                    lastErrorCode TEXT
                );
                CREATE INDEX pendingOperations_queue
                    ON pendingOperations(state, nextRetryAt, createdAt);

                CREATE TABLE tags (
                    id TEXT PRIMARY KEY NOT NULL,
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    name TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    UNIQUE(profileID, name COLLATE NOCASE)
                );

                CREATE TABLE transactionTags (
                    transactionID TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                    tagID TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    PRIMARY KEY(transactionID, tagID)
                ) WITHOUT ROWID;
                """
            )
        }

        migrator.registerMigration("v2_wallet_creation_security") { database in
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN backupState TEXT NOT NULL DEFAULT 'notVerified'
                    CHECK (backupState IN ('notVerified', 'verified'));
                ALTER TABLE wallets ADD COLUMN backupVerifiedAt REAL;
                ALTER TABLE wallets ADD COLUMN mnemonicWordCount INTEGER
                    CHECK (mnemonicWordCount IS NULL OR mnemonicWordCount IN (12, 15, 18, 21, 24));

                CREATE TABLE profileSecurity (
                    profileID TEXT PRIMARY KEY NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    passcodeKeychainReference TEXT NOT NULL,
                    failedAttemptCount INTEGER NOT NULL DEFAULT 0,
                    lockedUntil REAL,
                    updatedAt REAL NOT NULL
                );
                """
            )
        }

        migrator.registerMigration("v3_wallet_management") { database in
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN iCloudBackupUpdatedAt REAL;
                """
            )
        }

        migrator.registerMigration("v4_privacy_shield_setting") { database in
            try database.execute(
                sql: """
                ALTER TABLE userSettings
                    ADD COLUMN privacyShieldEnabled INTEGER NOT NULL DEFAULT 0;
                """
            )
        }

        migrator.registerMigration("v5_numbered_wallet_names") { database in
            let legacyNames = WalletDefaultName.legacyGenericNames
            var reservedNames = Set(
                try String.fetchAll(
                    database,
                    sql: """
                    SELECT name
                    FROM wallets
                    WHERE profileID = ? AND archivedAt IS NULL
                    """,
                    arguments: [defaultProfileID]
                )
            )
            let wallets = try DBWalletRecord
                .filter(Column("profileID") == defaultProfileID)
                .filter(Column("archivedAt") == nil)
                .order(Column("createdAt"), Column("sortOrder"))
                .fetchAll(database)

            for var wallet in wallets where legacyNames.contains(wallet.name) {
                reservedNames.remove(wallet.name)
                let kind = DatabaseWalletKind(rawValue: wallet.kind)
                    ?? .watchOnly
                wallet.name = WalletDefaultName.next(
                    for: kind,
                    excluding: reservedNames
                )
                reservedNames.insert(wallet.name)
                try wallet.update(database)
            }
        }

        migrator.registerMigration("v6_bitcoin_family_mainnets") { database in
            let now = Date().timeIntervalSince1970
            for (index, chain) in BitcoinFamilyChain.allCases.enumerated() {
                let record = DBNetworkRecord(
                    id: chain.networkID,
                    chainID: chain.databaseChainID,
                    nameKey: chain.nameKey,
                    nativeSymbol: chain.symbol,
                    trustWalletBlockchain: chain.blockchain.rawValue,
                    rpcProviderIdentifier: "electrum-\(chain.networkID)",
                    isMainnet: true,
                    isEnabled: true,
                    sortOrder: 10_000 + index,
                    createdAt: now,
                    updatedAt: now
                )
                if try DBNetworkRecord.fetchOne(
                    database,
                    key: chain.networkID
                ) == nil {
                    try record.insert(database)
                } else {
                    try record.update(database)
                }
            }
        }

        migrator.registerMigration("v7_solana_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: "solana",
                chainID: -501,
                nameKey: "network.solana.name",
                nativeSymbol: "SOL",
                trustWalletBlockchain: "solana",
                rpcProviderIdentifier: "ankr-solana",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_100,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }

        migrator.registerMigration("v8_tron_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: "tron",
                chainID: -195,
                nameKey: "network.tron.name",
                nativeSymbol: "TRX",
                trustWalletBlockchain: WalletBlockchain.tron.rawValue,
                rpcProviderIdentifier: "ankr-tron",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_200,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }

        migrator.registerMigration("v9_ton_mainnet") { database in
            let now = Date().timeIntervalSince1970
            if let providerOwner = try String.fetchOne(
                database,
                sql: """
                SELECT id
                FROM networks
                WHERE rpcProviderIdentifier = ? AND id <> ?
                """,
                arguments: ["ankr-ton", "ton"]
            ) {
                try database.execute(
                    sql: """
                    UPDATE networks
                    SET rpcProviderIdentifier = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        "legacy-\(providerOwner)-ankr-ton",
                        now,
                        providerOwner
                    ]
                )
            }
            let record = DBNetworkRecord(
                id: "ton",
                chainID: -607,
                nameKey: "network.ton.name",
                nativeSymbol: "TON",
                trustWalletBlockchain: "ton",
                rpcProviderIdentifier: "ankr-ton",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_300,
                createdAt: now,
                updatedAt: now
            )
            if try DBNetworkRecord.fetchOne(database, key: "ton") == nil {
                try record.insert(database)
            } else {
                try record.update(database)
            }
        }

        migrator.registerMigration("v10_unique_network_providers") {
            database in
            let now = Date().timeIntervalSince1970
            for chain in BitcoinFamilyChain.allCases {
                try database.execute(
                    sql: """
                    UPDATE networks
                    SET rpcProviderIdentifier = ?, updatedAt = ?
                    WHERE id = ?
                    """,
                    arguments: [
                        "electrum-\(chain.networkID)",
                        now,
                        chain.networkID
                    ]
                )
            }
        }

        migrator.registerMigration("v11_trust_wallet_dogecoin_identity") {
            database in
            try database.execute(
                sql: """
                UPDATE networks
                SET trustWalletBlockchain = 'doge'
                WHERE trustWalletBlockchain = 'dogecoin';

                UPDATE assets
                SET trustWalletBlockchain = 'doge'
                WHERE trustWalletBlockchain = 'dogecoin';
                """
            )
        }

        migrator.registerMigration("v12_remove_solana_and_ton") { database in
            let solanaRowsBefore = try solanaMetadataRowCount(database)
            let retiredNetworkID = "ton"
            try database.execute(
                sql: "DELETE FROM contactAddresses WHERE networkID = ?",
                arguments: [retiredNetworkID]
            )
            try database.execute(
                sql: "DELETE FROM nftCollections WHERE networkID = ?",
                arguments: [retiredNetworkID]
            )
            try database.execute(
                sql: "DELETE FROM walletAccounts WHERE networkID = ?",
                arguments: [retiredNetworkID]
            )
            try database.execute(
                sql: "DELETE FROM assets WHERE networkID = ?",
                arguments: [retiredNetworkID]
            )
            try database.execute(
                sql: "DELETE FROM dappPermissions WHERE chainID = ?",
                arguments: [-607]
            )
            try database.execute(
                sql: "DELETE FROM networks WHERE id = ?",
                arguments: [retiredNetworkID]
            )
            let solanaRowsAfter = try solanaMetadataRowCount(database)
            guard solanaRowsAfter == solanaRowsBefore else {
                throw DatabaseError(
                    resultCode: .SQLITE_CONSTRAINT,
                    message: "v12_solana_metadata_preservation_failed"
                )
            }
        }

        migrator.registerMigration("v13_asset_logo_metadata") { database in
            try database.alter(table: "assets") { table in
                table.add(column: "logoURL", .text)
                table.add(column: "logoOrigin", .text)
            }
            try database.execute(
                sql: "DELETE FROM apiCache WHERE provider = ?",
                arguments: ["trust-wallet-assets"]
            )
        }
        migrator.registerMigration("v14_reintroduce_solana_mainnet") {
            database in
            let now = Date().timeIntervalSince1970
            try database.execute(
                sql: """
                INSERT INTO networks (
                    id, chainID, nameKey, nativeSymbol,
                    trustWalletBlockchain, rpcProviderIdentifier,
                    isMainnet, isEnabled, sortOrder, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, 1, 1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    chainID = excluded.chainID,
                    nameKey = excluded.nameKey,
                    nativeSymbol = excluded.nativeSymbol,
                    trustWalletBlockchain = excluded.trustWalletBlockchain,
                    rpcProviderIdentifier = excluded.rpcProviderIdentifier,
                    isMainnet = 1,
                    updatedAt = excluded.updatedAt
                """,
                arguments: [
                    SolanaConstants.networkID, -501,
                    "network.solana.name", "SOL",
                    WalletBlockchain.solana.rawValue,
                    "ankr-solana-jsonrpc", 10_100, now, now
                ]
            )
            try database.execute(
                sql: """
                CREATE TABLE solanaSyncState (
                    accountID TEXT PRIMARY KEY NOT NULL
                        REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    newestSignature TEXT,
                    oldestSignature TEXT,
                    providerHistoryComplete INTEGER NOT NULL DEFAULT 0,
                    updatedAt REAL NOT NULL
                );
                """
            )
        }
        migrator.registerMigration(
            "v15_solana_history_cursor_addresses"
        ) { database in
            try database.rename(
                table: "solanaSyncState",
                to: "solanaSyncStateByAccount"
            )
            try database.execute(
                sql: """
                CREATE TABLE solanaSyncState (
                    address TEXT PRIMARY KEY NOT NULL,
                    accountID TEXT NOT NULL
                        REFERENCES walletAccounts(id) ON DELETE CASCADE,
                    newestSignature TEXT,
                    oldestSignature TEXT,
                    providerHistoryComplete INTEGER NOT NULL DEFAULT 0,
                    updatedAt REAL NOT NULL
                );

                INSERT INTO solanaSyncState (
                    address,
                    accountID,
                    newestSignature,
                    oldestSignature,
                    providerHistoryComplete,
                    updatedAt
                )
                SELECT
                    account.address,
                    state.accountID,
                    state.newestSignature,
                    state.oldestSignature,
                    state.providerHistoryComplete,
                    state.updatedAt
                FROM solanaSyncStateByAccount AS state
                JOIN walletAccounts AS account
                    ON account.id = state.accountID;

                DROP TABLE solanaSyncStateByAccount;

                CREATE INDEX solanaSyncState_accountID
                    ON solanaSyncState(accountID);
                """
            )
        }

        migrator.registerMigration(
            "v16_remote_notification_registration"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE userSettings ADD COLUMN
                    receivedTransactionNotificationsEnabled INTEGER
                    NOT NULL DEFAULT 1;
                ALTER TABLE userSettings ADD COLUMN
                    sentTransactionNotificationsEnabled INTEGER
                    NOT NULL DEFAULT 0;
                ALTER TABLE userSettings ADD COLUMN
                    adminNotificationsEnabled INTEGER
                    NOT NULL DEFAULT 1;

                ALTER TABLE notifications ADD COLUMN
                    remoteNotificationID TEXT;
                ALTER TABLE notifications ADD COLUMN titleText TEXT;
                ALTER TABLE notifications ADD COLUMN bodyText TEXT;
                ALTER TABLE notifications ADD COLUMN walletID TEXT;
                ALTER TABLE notifications ADD COLUMN networkID TEXT;
                ALTER TABLE notifications ADD COLUMN transactionHash TEXT;
                ALTER TABLE notifications ADD COLUMN openedAt REAL;

                CREATE UNIQUE INDEX notifications_remote_id
                    ON notifications(remoteNotificationID)
                    WHERE remoteNotificationID IS NOT NULL;

                CREATE TABLE notificationProfiles (
                    profileID TEXT PRIMARY KEY NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    remoteUserID TEXT NOT NULL UNIQUE,
                    reconciliationNeeded INTEGER NOT NULL DEFAULT 1,
                    lastSnapshotDigest TEXT,
                    lastRegistrationAttemptAt REAL,
                    lastRegistrationSuccessAt REAL,
                    lastRegistrationErrorCode TEXT,
                    updatedAt REAL NOT NULL
                );
                """
            )
        }

        migrator.registerMigration(
            "v17_notification_delivery_outbox"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE notificationProfiles ADD COLUMN
                    installationID TEXT;
                ALTER TABLE notificationProfiles ADD COLUMN
                    reconciliationGeneration INTEGER
                    NOT NULL DEFAULT 0;

                CREATE TABLE notificationOpenAudits (
                    notificationID TEXT PRIMARY KEY NOT NULL,
                    createdAt REAL NOT NULL,
                    attemptCount INTEGER NOT NULL DEFAULT 0
                        CHECK (attemptCount >= 0),
                    lastAttemptAt REAL,
                    nextAttemptAt REAL NOT NULL,
                    lastErrorCode TEXT
                );
                CREATE INDEX notificationOpenAudits_due
                    ON notificationOpenAudits(
                        nextAttemptAt,
                        createdAt
                    );
                """
            )
        }

        migrator.registerMigration(
            "v18_notification_history_backfill"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE notificationProfiles ADD COLUMN
                    historyBackfillCursor TEXT;
                """
            )
        }

        migrator.registerMigration(
            "v19_inactive_wallet_notifications"
        ) { database in
            try database.execute(
                sql: """
                ALTER TABLE wallets ADD COLUMN
                    notificationsEnabledWhenInactive INTEGER
                    NOT NULL DEFAULT 0
                    CHECK (
                        notificationsEnabledWhenInactive IN (0, 1)
                    );
                """
            )
        }

        migrator.registerMigration(
            "v20_local_transaction_notes"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE transactionNotes (
                    transactionID TEXT PRIMARY KEY NOT NULL
                        REFERENCES transactions(id) ON DELETE CASCADE,
                    note TEXT NOT NULL
                        CHECK (
                            length(note) > 0
                            AND length(note) <= 1000
                        ),
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL
                ) WITHOUT ROWID;
                """
            )
        }

        migrator.registerMigration(
            "v21_send_network_fee_preferences"
        ) { database in
            try database.execute(
                sql: """
                CREATE TABLE sendFeePreferences (
                    profileID TEXT PRIMARY KEY NOT NULL
                        REFERENCES profiles(id) ON DELETE CASCADE,
                    preset TEXT NOT NULL DEFAULT 'fastest'
                        CHECK (
                            preset IN (
                                'fastest', 'standard',
                                'economy', 'custom'
                            )
                        ),
                    updatedAt REAL NOT NULL
                );

                CREATE TABLE sendCustomFeePreferences (
                    profileID TEXT NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL
                        REFERENCES networks(id) ON DELETE CASCADE,
                    model TEXT NOT NULL,
                    primaryValue TEXT NOT NULL
                        CHECK (
                            length(primaryValue) > 0
                            AND primaryValue NOT GLOB '*[^0-9]*'
                        ),
                    secondaryValue TEXT
                        CHECK (
                            secondaryValue IS NULL
                            OR (
                                length(secondaryValue) > 0
                                AND secondaryValue
                                    NOT GLOB '*[^0-9]*'
                            )
                        ),
                    updatedAt REAL NOT NULL,
                    PRIMARY KEY(profileID, networkID)
                ) WITHOUT ROWID;
                """
            )
        }

        registerPostCoreMigrations(on: &migrator)
        registerUniversalSearchMigrations(on: &migrator)
        registerRetiredStorageCleanup(on: &migrator)
        registerAssetCatalogMigration(on: &migrator)
        registerWalletAccountDerivationMigration(on: &migrator)
        registerSendRecipientBroadcastMigration(on: &migrator)
        registerSendRecipientMemoMigration(on: &migrator)
        registerSendCustomFeeBudgetMigration(on: &migrator)
        registerAppReviewPromptMigration(on: &migrator)
        migrator.registerMigration(
            "v48_imported_wallet_default_names"
        ) { database in
            try WalletDefaultName.migrateLegacyImportedNames(
                in: database
            )
        }
        registerRemoteAssetCatalogMigration(on: &migrator)
        migrator.registerMigration(
            "v50_wallet_balance_history"
        ) { _ in }
        migrator.registerMigration(
            "v51_remove_wallet_balance_history"
        ) { database in
            try database.execute(
                sql: "DROP TABLE IF EXISTS walletBalanceSnapshots"
            )
        }
        registerBitcoinHDWalletMigration(on: &migrator)
        registerBitcoinHDChangeReservationMigration(on: &migrator)
        registerBitcoinHDKeyCacheMigration(on: &migrator)
        registerBitcoinSilentPaymentMigration(on: &migrator)
        registerBitcoinHDAddressSelectionMigration(on: &migrator)
        registerCurrencyConverterMigration(on: &migrator)
        migrator.registerMigration(
            "v59_remove_retired_invoice_tables"
        ) { database in
            try database.execute(
                sql: """
                DROP TABLE IF EXISTS pointOfSaleHistorySyncPreferences;
                DROP TABLE IF EXISTS pointOfSaleInvoices;
                """
            )
        }
        registerEVMApprovalMigration(on: &migrator)
        registerLegacyWalletSyncDiagnosticsMigration(on: &migrator)
        registerSendSpendReservationMigration(on: &migrator)
        registerBitcoinBIP84ReceiveDefaultMigration(on: &migrator)
        registerMuunRecoveryMigration(on: &migrator)
        registerDeveloperLogRemovalMigration(on: &migrator)
        registerBitcoinSilentPaymentBalanceAuthorityMigration(
            on: &migrator
        )
        registerBitcoinSilentPaymentScanProgressMigration(
            on: &migrator
        )
        registerTransactionSearchPerformanceMigration(on: &migrator)
        registerWalletRefreshPolicyMigration(on: &migrator)
        registerSendPendingResourcesMigration(on: &migrator)
        registerTronPermissionCheckMigration(on: &migrator)
        registerStablecoinBlacklistMigration(on: &migrator)
        registerBitcoinBRDMigration(on: &migrator)
        registerBitcoinImportedWalletMigration(on: &migrator)
        registerNotificationLocalizationMigration(on: &migrator)
        registerSendStatusTrackingMigration(on: &migrator)
        registerTokenDEXPriceMigration(on: &migrator)
        registerAssetCatalogFamilyMigration(on: &migrator)
        registerAssetCatalogScopeMigration(on: &migrator)
        registerBitcoinFamilyHDMigration(on: &migrator)
        registerPendingTransactionReconciliationMigration(on: &migrator)
        registerNetworkFeeCacheMigration(on: &migrator)
        return migrator
    }
}
