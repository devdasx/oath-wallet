import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrations = DatabaseMigrator()
        // Never enable eraseDatabaseOnSchemaChange: migrations must preserve wallets.
        migrations.registerMigration("v1_wallet_ledger") { db in
            try db.execute(sql: """
            CREATE TABLE networks (
                id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, family TEXT NOT NULL,
                symbol TEXT NOT NULL, decimals INTEGER NOT NULL CHECK(decimals BETWEEN 0 AND 255),
                derivationPath TEXT NOT NULL, logo TEXT NOT NULL, sortOrder INTEGER NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1))
            );
            CREATE TABLE wallets (
                id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, kind TEXT NOT NULL,
                vaultReference TEXT NOT NULL UNIQUE, createdAt DOUBLE NOT NULL,
                backedUp INTEGER NOT NULL CHECK(backedUp IN (0,1))
            );
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                networkID TEXT NOT NULL REFERENCES networks(id), address TEXT NOT NULL,
                derivationPath TEXT NOT NULL, accountIndex INTEGER NOT NULL CHECK(accountIndex >= 0),
                syncGeneration INTEGER NOT NULL DEFAULT 0,
                UNIQUE(walletID, networkID, address), UNIQUE(id, networkID), UNIQUE(id, walletID)
            );
            CREATE INDEX accounts_wallet_network ON accounts(walletID, networkID, id);
            CREATE INDEX accounts_network_address ON accounts(networkID, address);
            CREATE TABLE assets (
                id TEXT PRIMARY KEY NOT NULL, networkID TEXT NOT NULL REFERENCES networks(id),
                reference TEXT NOT NULL, name TEXT NOT NULL, symbol TEXT NOT NULL,
                decimals INTEGER NOT NULL CHECK(decimals BETWEEN 0 AND 255), logo TEXT,
                UNIQUE(networkID, reference), UNIQUE(id, networkID)
            );
            CREATE INDEX assets_symbol ON assets(symbol COLLATE NOCASE, id);
            CREATE TABLE balances (
                accountID TEXT NOT NULL, assetID TEXT NOT NULL, networkID TEXT NOT NULL,
                amountAtomic TEXT NOT NULL CHECK(amountAtomic <> '' AND amountAtomic NOT GLOB '*[^0-9]*'
                    AND (length(amountAtomic)=1 OR substr(amountAtomic,1,1)<>'0')),
                observedAt DOUBLE NOT NULL, blockHeight INTEGER, source TEXT NOT NULL,
                PRIMARY KEY(accountID, assetID),
                FOREIGN KEY(accountID, networkID) REFERENCES accounts(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(assetID, networkID) REFERENCES assets(id, networkID) ON DELETE CASCADE
            );
            CREATE INDEX balances_asset ON balances(assetID, accountID);
            CREATE TABLE prices (
                assetID TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                currency TEXT NOT NULL, value TEXT NOT NULL, observedAt DOUBLE NOT NULL,
                source TEXT NOT NULL, PRIMARY KEY(assetID, currency, observedAt)
            );
            CREATE INDEX prices_latest ON prices(assetID, currency, observedAt DESC);
            CREATE TABLE transactions (
                id TEXT PRIMARY KEY NOT NULL, networkID TEXT NOT NULL REFERENCES networks(id),
                hash TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','confirmed','failed','replaced','reorged')),
                blockHeight INTEGER, blockHash TEXT, timestamp DOUBLE NOT NULL,
                feeAtomic TEXT, updatedAt DOUBLE NOT NULL,
                UNIQUE(networkID, hash), UNIQUE(id, networkID)
            );
            CREATE INDEX transactions_block ON transactions(networkID, blockHeight) WHERE blockHeight IS NOT NULL;
            CREATE INDEX transactions_pending ON transactions(networkID, updatedAt) WHERE state='pending';
            CREATE TABLE transfers (
                id TEXT PRIMARY KEY NOT NULL, transactionID TEXT NOT NULL, networkID TEXT NOT NULL,
                assetID TEXT NOT NULL, eventIndex INTEGER NOT NULL, fromAddress TEXT NOT NULL,
                toAddress TEXT NOT NULL, amountAtomic TEXT NOT NULL,
                UNIQUE(transactionID, eventIndex, assetID),
                FOREIGN KEY(transactionID, networkID) REFERENCES transactions(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(assetID, networkID) REFERENCES assets(id, networkID)
            );
            CREATE INDEX transfers_transaction ON transfers(transactionID, eventIndex);
            CREATE TABLE activity (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL, networkID TEXT NOT NULL, transactionID TEXT NOT NULL,
                assetID TEXT NOT NULL, direction TEXT NOT NULL CHECK(direction IN ('incoming','outgoing','self')),
                amountAtomic TEXT NOT NULL, counterparty TEXT NOT NULL, timestamp DOUBLE NOT NULL,
                FOREIGN KEY(accountID, walletID) REFERENCES accounts(id, walletID) ON DELETE CASCADE,
                FOREIGN KEY(accountID, networkID) REFERENCES accounts(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(transactionID, networkID) REFERENCES transactions(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(assetID, networkID) REFERENCES assets(id, networkID)
            );
            CREATE INDEX activity_wallet_page ON activity(walletID, timestamp DESC, id DESC);
            CREATE INDEX activity_account_page ON activity(accountID, timestamp DESC, id DESC);
            CREATE INDEX activity_transaction ON activity(transactionID, walletID);
            CREATE INDEX activity_asset_page ON activity(walletID, assetID, timestamp DESC, id DESC);
            CREATE TABLE sends (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL, networkID TEXT NOT NULL, assetID TEXT NOT NULL, senderAddress TEXT NOT NULL,
                idempotencyKey TEXT NOT NULL UNIQUE, recipient TEXT NOT NULL, amountAtomic TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('draft','queued','signed','broadcast','confirmed','failed','cancelled')),
                nonce TEXT, signedPayload BLOB, transactionID TEXT, failureCode TEXT,
                createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
                FOREIGN KEY(accountID, walletID) REFERENCES accounts(id, walletID) ON DELETE CASCADE,
                FOREIGN KEY(accountID, networkID) REFERENCES accounts(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(assetID, networkID) REFERENCES assets(id, networkID),
                FOREIGN KEY(transactionID, networkID) REFERENCES transactions(id, networkID)
            );
            CREATE INDEX sends_wallet_page ON sends(walletID, createdAt DESC, id DESC);
            CREATE INDEX sends_outbox ON sends(state, updatedAt) WHERE state IN ('queued','signed','broadcast');
            CREATE UNIQUE INDEX sends_reserved_nonce ON sends(networkID, senderAddress, nonce)
                WHERE nonce IS NOT NULL AND state IN ('queued','signed','broadcast');
            CREATE TABLE utxos (
                networkID TEXT NOT NULL, transactionHash TEXT NOT NULL, outputIndex INTEGER NOT NULL CHECK(outputIndex >= 0),
                value INTEGER NOT NULL CHECK(value >= 0), script TEXT NOT NULL,
                blockHeight INTEGER, spent INTEGER NOT NULL CHECK(spent IN (0,1)),
                reservedBy TEXT REFERENCES sends(id) ON DELETE SET NULL, updatedAt DOUBLE NOT NULL,
                PRIMARY KEY(networkID, transactionHash, outputIndex),
                FOREIGN KEY(networkID) REFERENCES networks(id)
            );
            CREATE INDEX utxos_spendable ON utxos(networkID, value, transactionHash, outputIndex)
                WHERE spent=0 AND reservedBy IS NULL;
            CREATE INDEX utxos_reservations ON utxos(reservedBy) WHERE reservedBy IS NOT NULL;
            CREATE INDEX utxos_reorg ON utxos(networkID, blockHeight) WHERE blockHeight IS NOT NULL;
            CREATE TABLE accountUTXOs (
                accountID TEXT NOT NULL, networkID TEXT NOT NULL, transactionHash TEXT NOT NULL, outputIndex INTEGER NOT NULL,
                PRIMARY KEY(accountID, networkID, transactionHash, outputIndex),
                FOREIGN KEY(accountID, networkID) REFERENCES accounts(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(networkID, transactionHash, outputIndex) REFERENCES utxos(networkID, transactionHash, outputIndex) ON DELETE CASCADE
            );
            CREATE INDEX account_utxos_outpoint ON accountUTXOs(networkID, transactionHash, outputIndex, accountID);
            CREATE TABLE receives (
                id TEXT PRIMARY KEY NOT NULL, accountID TEXT NOT NULL, networkID TEXT NOT NULL,
                assetID TEXT NOT NULL, address TEXT NOT NULL, amountAtomic TEXT, memo TEXT,
                state TEXT NOT NULL CHECK(state IN ('open','fulfilled','expired','cancelled')),
                createdAt DOUBLE NOT NULL, expiresAt DOUBLE,
                FOREIGN KEY(accountID, networkID) REFERENCES accounts(id, networkID) ON DELETE CASCADE,
                FOREIGN KEY(assetID, networkID) REFERENCES assets(id, networkID)
            );
            CREATE INDEX receives_account_page ON receives(accountID, createdAt DESC, id DESC);
            CREATE TABLE notes (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                subjectType TEXT NOT NULL, subjectID TEXT NOT NULL, body TEXT NOT NULL, updatedAt DOUBLE NOT NULL,
                UNIQUE(walletID, subjectType, subjectID)
            );
            CREATE INDEX notes_wallet_date ON notes(walletID, updatedAt DESC, id DESC);
            CREATE VIRTUAL TABLE notesSearch USING fts5(body,content='notes',content_rowid='rowid');
            CREATE TRIGGER notes_insert AFTER INSERT ON notes BEGIN
                INSERT INTO notesSearch(rowid,body) VALUES (new.rowid,new.body);
            END;
            CREATE TRIGGER notes_delete AFTER DELETE ON notes BEGIN
                INSERT INTO notesSearch(notesSearch,rowid,body) VALUES ('delete',old.rowid,old.body);
            END;
            CREATE TRIGGER notes_update AFTER UPDATE ON notes BEGIN
                INSERT INTO notesSearch(notesSearch,rowid,body) VALUES ('delete',old.rowid,old.body);
                INSERT INTO notesSearch(rowid,body) VALUES (new.rowid,new.body);
            END;
            CREATE TABLE labels (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                name TEXT NOT NULL, color TEXT NOT NULL, updatedAt DOUBLE NOT NULL,
                UNIQUE(walletID, name), UNIQUE(id, walletID)
            );
            CREATE TABLE labelAssignments (
                labelID TEXT NOT NULL, walletID TEXT NOT NULL, subjectType TEXT NOT NULL, subjectID TEXT NOT NULL,
                PRIMARY KEY(labelID, subjectType, subjectID),
                FOREIGN KEY(labelID, walletID) REFERENCES labels(id, walletID) ON DELETE CASCADE
            );
            CREATE INDEX labels_subject ON labelAssignments(walletID, subjectType, subjectID, labelID);
            CREATE TABLE syncCursors (
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                stream TEXT NOT NULL, cursor TEXT NOT NULL, blockHeight INTEGER, blockHash TEXT,
                updatedAt DOUBLE NOT NULL, PRIMARY KEY(accountID, stream)
            );
            CREATE TABLE settings (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL, updatedAt DOUBLE NOT NULL);
            CREATE TABLE metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
            """)
        }
        migrations.registerMigration("v2_encrypted_icloud_backups") { db in
            try db.execute(sql: """
                CREATE TABLE cloudBackups (
                    walletID TEXT PRIMARY KEY NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    backupID TEXT NOT NULL UNIQUE, accountID TEXT NOT NULL,
                    enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
                    state TEXT NOT NULL CHECK(state IN ('queued','uploading','uploaded','failed')),
                    encryptedDocument BLOB, createdAt DOUBLE NOT NULL, uploadedAt DOUBLE,
                    percent DOUBLE CHECK(percent BETWEEN 0 AND 100), failureCode TEXT
                );
                CREATE INDEX cloud_backups_pending ON cloudBackups(accountID, state)
                    WHERE enabled=1 AND state<>'uploaded';
                """)
        }
        migrations.registerMigration("v3_wallet_appearance") { db in
            // Existing wallets keep the original cobalt artwork. The wallet's
            // primary key already indexes every appearance read and update.
            try db.execute(sql: """
                ALTER TABLE wallets ADD COLUMN colorHex TEXT
                    CHECK(colorHex IS NULL OR (length(colorHex)=6 AND colorHex NOT GLOB '*[^0-9A-F]*'));
                """)
        }
        migrations.registerMigration("v4_wallet_customization_completion") { db in
            // Upgrades never send existing wallets through setup again. Only
            // new local creation/import explicitly opts into this step.
            try db.execute(sql: "ALTER TABLE wallets ADD COLUMN needsCustomization INTEGER NOT NULL DEFAULT 0 CHECK(needsCustomization IN (0,1))")
        }
        migrations.registerMigration("v5_contacts") { db in
            try db.execute(sql: """
                CREATE TABLE contacts (
                    id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL CHECK(length(name) BETWEEN 1 AND 100),
                    searchText TEXT NOT NULL, createdAt DOUBLE NOT NULL, updatedAt DOUBLE NOT NULL,
                    revision INTEGER NOT NULL CHECK(revision > 0)
                );
                CREATE INDEX contacts_name ON contacts(name COLLATE NOCASE, id);
                CREATE TABLE contactAddresses (
                    id TEXT PRIMARY KEY NOT NULL,
                    contactID TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL REFERENCES networks(id),
                    address TEXT NOT NULL CHECK(length(address) BETWEEN 1 AND 256),
                    addressKey TEXT NOT NULL, label TEXT NOT NULL CHECK(length(label) <= 60),
                    position INTEGER NOT NULL CHECK(position >= 0),
                    UNIQUE(contactID, networkID, addressKey)
                );
                CREATE INDEX contact_addresses_order ON contactAddresses(contactID, position, id);
                CREATE INDEX contact_addresses_lookup ON contactAddresses(networkID, addressKey, contactID);
                CREATE VIRTUAL TABLE contactsSearch USING fts5(name, searchText,
                    content='contacts', content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
                CREATE TRIGGER contacts_insert AFTER INSERT ON contacts BEGIN
                    INSERT INTO contactsSearch(rowid,name,searchText) VALUES(new.rowid,new.name,new.searchText);
                END;
                CREATE TRIGGER contacts_delete AFTER DELETE ON contacts BEGIN
                    INSERT INTO contactsSearch(contactsSearch,rowid,name,searchText)
                    VALUES('delete',old.rowid,old.name,old.searchText);
                END;
                CREATE TRIGGER contacts_update AFTER UPDATE OF name,searchText ON contacts BEGIN
                    INSERT INTO contactsSearch(contactsSearch,rowid,name,searchText)
                    VALUES('delete',old.rowid,old.name,old.searchText);
                    INSERT INTO contactsSearch(rowid,name,searchText) VALUES(new.rowid,new.name,new.searchText);
                END;
                CREATE TRIGGER contacts_network_renamed AFTER UPDATE OF name,symbol ON networks BEGIN
                    UPDATE contacts SET searchText=(
                        SELECT group_concat(a.label || ' ' || n.id || ' ' || n.name || ' ' || n.symbol || ' ' || a.address, ' ')
                        FROM contactAddresses a JOIN networks n ON n.id=a.networkID WHERE a.contactID=contacts.id
                    ) WHERE id IN (SELECT contactID FROM contactAddresses WHERE networkID=new.id);
                END;
                """)
        }
        migrations.registerMigration("v6_usd_exchange_rates") { db in
            try db.execute(sql: """
                CREATE TABLE exchangeRateMetadata (
                    base TEXT PRIMARY KEY NOT NULL CHECK(base='USD'),
                    observedAt DOUBLE NOT NULL, fetchedAt DOUBLE NOT NULL, source TEXT NOT NULL
                );
                CREATE TABLE exchangeRates (
                    currency TEXT PRIMARY KEY NOT NULL CHECK(length(currency)=3),
                    unitsPerUSD TEXT NOT NULL
                );
                """)
        }
        migrations.registerMigration("v7_resumable_wallet_reset") { db in
            // Enforce the deletion boundary in SQLite as well as the actors.
            // A delayed provider callback cannot write wallet data mid-reset.
            // Migration membership is frozen: future tables do not exist yet
            // when a fresh installation runs this older migration.
            for table in ["wallets", "accounts", "balances", "transactions", "transfers", "activity",
                          "sends", "utxos", "accountUTXOs", "receives", "notes", "labels", "labelAssignments", "syncCursors",
                          "cloudBackups", "contacts", "contactAddresses"] {
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v8_tracked_tokens") { db in
            try db.execute(sql: """
                CREATE TABLE trackedAssets (
                    accountID TEXT NOT NULL, assetID TEXT NOT NULL, networkID TEXT NOT NULL,
                    addedAt DOUBLE NOT NULL,
                    PRIMARY KEY(accountID, assetID),
                    FOREIGN KEY(accountID, networkID) REFERENCES accounts(id, networkID) ON DELETE CASCADE,
                    FOREIGN KEY(assetID, networkID) REFERENCES assets(id, networkID) ON DELETE CASCADE
                );
                CREATE INDEX tracked_assets_network ON trackedAssets(networkID, accountID);
                """)
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_trackedAssets_\(operation) BEFORE \(operation) ON trackedAssets
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
        migrations.registerMigration("v9_public_market_cache") { db in
            // Public quotes, descriptions, chart series and provider identities
            // survive wallet deletion/reset. No addresses or private data here.
            try db.execute(sql: """
                CREATE TABLE publicMarketCache (
                    key TEXT PRIMARY KEY NOT NULL,
                    source TEXT NOT NULL,
                    payload BLOB NOT NULL,
                    fetchedAt DOUBLE NOT NULL
                );
                """)
        }
        migrations.registerMigration("v10_bitcoin_discovery") { db in
            try db.execute(sql: """
                CREATE TABLE bitcoinWallets (
                    accountID TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    descriptor BLOB NOT NULL, preferredType INTEGER NOT NULL,
                    scanID TEXT, lastSuccess DOUBLE, failure TEXT, tipHeight INTEGER,
                    confirmed INTEGER NOT NULL DEFAULT 0, unconfirmed INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE bitcoinAddresses (
                    accountID TEXT NOT NULL REFERENCES bitcoinWallets(accountID) ON DELETE CASCADE,
                    branchID TEXT NOT NULL, addressIndex INTEGER NOT NULL CHECK(addressIndex >= 0),
                    address TEXT NOT NULL, script TEXT NOT NULL, scriptHash TEXT NOT NULL,
                    detail BLOB NOT NULL, used INTEGER NOT NULL DEFAULT 0, issued INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(accountID, branchID, addressIndex), UNIQUE(accountID, scriptHash)
                );
                CREATE INDEX bitcoin_address_script ON bitcoinAddresses(accountID, script);
                CREATE INDEX bitcoin_address_gap ON bitcoinAddresses(accountID, branchID, used, issued, addressIndex);
                CREATE TABLE bitcoinHistory (
                    accountID TEXT NOT NULL REFERENCES bitcoinWallets(accountID) ON DELETE CASCADE,
                    txid TEXT NOT NULL, height INTEGER NOT NULL,
                    PRIMARY KEY(accountID, txid)
                );
                CREATE INDEX bitcoin_history_page ON bitcoinHistory(accountID, height DESC, txid);
                CREATE TABLE bitcoinTransactions (
                    accountID TEXT NOT NULL REFERENCES bitcoinWallets(accountID) ON DELETE CASCADE,
                    txid TEXT NOT NULL, raw BLOB NOT NULL,
                    PRIMARY KEY(accountID, txid)
                );
                """)
            for table in ["bitcoinWallets", "bitcoinAddresses", "bitcoinHistory", "bitcoinTransactions"] {
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v11_ankr_account_sync") { db in
            try db.execute(sql: """
                CREATE TABLE ankrSync (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, runID TEXT, scanID TEXT, cursor TEXT, windowStart INTEGER NOT NULL DEFAULT 0,
                    windowEnd INTEGER NOT NULL DEFAULT 0, complete INTEGER NOT NULL DEFAULT 0,
                    lastSuccess DOUBLE, failure TEXT, syncStatus BLOB, totalBalanceUsd TEXT, totalCount INTEGER,
                    PRIMARY KEY(accountID,stream)
                );
                CREATE TABLE ankrResponses (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, pageKey TEXT NOT NULL, raw BLOB NOT NULL, fetchedAt DOUBLE NOT NULL,
                    PRIMARY KEY(accountID,stream,pageKey)
                );
                CREATE TABLE ankrAssets (
                    accountID TEXT NOT NULL, assetID TEXT NOT NULL, detail BLOB NOT NULL,
                    balanceUsd TEXT NOT NULL, fetchedAt DOUBLE NOT NULL,
                    PRIMARY KEY(accountID,assetID),
                    FOREIGN KEY(accountID) REFERENCES accounts(id) ON DELETE CASCADE,
                    FOREIGN KEY(assetID) REFERENCES assets(id) ON DELETE CASCADE
                );
                CREATE TABLE ankrActivity (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    activityID TEXT NOT NULL REFERENCES activity(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, seenRun TEXT NOT NULL,
                    PRIMARY KEY(accountID,activityID)
                );
                CREATE INDEX ankr_activity_stream ON ankrActivity(accountID,stream,seenRun);
                """)
            for table in ["ankrSync","ankrResponses","ankrAssets","ankrActivity"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v12_ankr_whitelisted_holdings") { db in
            // Old inventories explicitly requested unlisted tokens. They
            // cannot establish whitelist membership, even when a price exists.
            // Hide those automatic holdings until a filtered refresh succeeds.
            try db.execute(sql: """
                ALTER TABLE ankrAssets ADD COLUMN onlyWhitelisted INTEGER NOT NULL DEFAULT 0
                    CHECK(onlyWhitelisted IN (0,1));
                """)
        }
        migrations.registerMigration("v13_asset_activity_order") { db in
            try db.execute(sql: """
                CREATE INDEX activity_wallet_asset_transaction ON activity(walletID,accountID,assetID,transactionID);
                """)
        }
        migrations.registerMigration("v14_solana_receive_paths") { db in
            try db.execute(sql: """
                CREATE TABLE solanaReceiveAddresses (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    path TEXT NOT NULL, address TEXT NOT NULL,
                    isSelected INTEGER NOT NULL CHECK(isSelected IN (0,1)),
                    PRIMARY KEY(accountID,path), UNIQUE(accountID,address)
                );
                CREATE UNIQUE INDEX solana_receive_selected ON solanaReceiveAddresses(accountID) WHERE isSelected=1;
                """)
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_solanaReceiveAddresses_\(operation) BEFORE \(operation) ON solanaReceiveAddresses
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
        migrations.registerMigration("v15_solana_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE solanaSync (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    owner TEXT NOT NULL, runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE,
                    minimumSlot INTEGER, failure TEXT, historyFailure TEXT,
                    PRIMARY KEY(accountID,owner)
                );
                CREATE TABLE solanaHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    owner TEXT NOT NULL, assetID TEXT NOT NULL REFERENCES assets(id),
                    amountAtomic TEXT NOT NULL, observedAt DOUBLE NOT NULL, slot INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)),
                    PRIMARY KEY(accountID,owner,assetID)
                );
                CREATE TABLE solanaHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    owner TEXT NOT NULL, address TEXT NOT NULL, head TEXT, before TEXT,
                    complete INTEGER NOT NULL DEFAULT 0, pendingBefore TEXT, pendingHead TEXT,
                    lastChecked DOUBLE NOT NULL DEFAULT 0, priority INTEGER NOT NULL DEFAULT 2,
                    PRIMARY KEY(accountID,owner,address)
                );
                CREATE INDEX solana_history_work ON solanaHistoryCursors(accountID,owner,lastChecked,priority);
                CREATE TABLE solanaTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    owner TEXT NOT NULL, signature TEXT NOT NULL, detail BLOB NOT NULL,
                    PRIMARY KEY(accountID,owner,signature)
                );
                CREATE TABLE solanaActivity (
                    activityID TEXT PRIMARY KEY REFERENCES activity(id) ON DELETE CASCADE,
                    owner TEXT NOT NULL
                );
                """)
            for table in ["solanaSync", "solanaHoldings", "solanaHistoryCursors", "solanaTransactions", "solanaActivity"] {
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v16_tron_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE tronSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE tronHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    assetID TEXT NOT NULL REFERENCES assets(id), amountAtomic TEXT NOT NULL,
                    observedAt DOUBLE NOT NULL, verified INTEGER NOT NULL CHECK(verified IN (0,1)),
                    PRIMARY KEY(accountID,assetID)
                );
                CREATE TABLE tronHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL,
                    cursor TEXT, complete INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE tronTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,hash)
                );
                CREATE TABLE tronPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, start INTEGER NOT NULL, end INTEGER NOT NULL,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,stream,start,end,pageKey)
                );
                """)
            for table in ["tronSync", "tronHoldings", "tronHistoryCursors", "tronTransactions", "tronPages"] {
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v17_ton_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE tonSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE tonHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    assetID TEXT NOT NULL REFERENCES assets(id), amountAtomic TEXT NOT NULL,
                    observedAt DOUBLE NOT NULL, verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,assetID)
                );
                CREATE TABLE tonHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, beforeLT INTEGER, stopLT INTEGER, headLT INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE tonTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, hash TEXT NOT NULL, eventKey TEXT NOT NULL, detail BLOB NOT NULL,
                    PRIMARY KEY(accountID,stream,hash,eventKey)
                );
                CREATE TABLE tonPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,stream,pageKey)
                );
                """)
            for table in ["tonSync", "tonHoldings", "tonHistoryCursors", "tonTransactions", "tonPages"] {
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v18_aptos_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE aptosSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, ledgerVersion INTEGER, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE aptosHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    assetID TEXT NOT NULL REFERENCES assets(id), amountAtomic TEXT NOT NULL,
                    observedAt DOUBLE NOT NULL, verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,assetID)
                );
                CREATE TABLE aptosHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, beforeVersion INTEGER, stopVersion INTEGER, headVersion INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE aptosTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    hash TEXT NOT NULL, version INTEGER NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,hash)
                );
                CREATE TABLE aptosPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,stream,pageKey)
                );
                """)
            for table in ["aptosSync","aptosHoldings","aptosHistoryCursors","aptosTransactions","aptosPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }

        migrations.registerMigration("v19_sui_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE suiSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE suiHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT REFERENCES assets(id), amountAtomic TEXT NOT NULL,
                    coinBalance TEXT NOT NULL, addressBalance TEXT NOT NULL,
                    observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX suiHoldingsAsset ON suiHoldings(accountID,assetID);
                CREATE TABLE suiHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    lane TEXT NOT NULL, beforeCursor TEXT, upperCheckpoint INTEGER, oldestCheckpoint INTEGER,
                    stopHash TEXT, headHash TEXT, complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(accountID,lane)
                );
                CREATE TABLE suiTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    hash TEXT NOT NULL, checkpoint INTEGER NOT NULL, detail BLOB NOT NULL,
                    unresolved INTEGER NOT NULL, PRIMARY KEY(accountID,hash)
                );
                CREATE INDEX suiUnresolvedTransactions ON suiTransactions(accountID) WHERE unresolved=1;
                CREATE TABLE suiPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["suiSync","suiHoldings","suiHistoryCursors","suiTransactions","suiPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v20_near_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE nearSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, blockHeight INTEGER, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE nearHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT REFERENCES assets(id), amountAtomic TEXT,
                    observedAt DOUBLE NOT NULL, blockHeight INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), failure TEXT, PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX nearHoldingsAsset ON nearHoldings(accountID,assetID);
                CREATE TABLE nearHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, beforeCursor TEXT, stopID TEXT, headID TEXT,
                    complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE nearTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,hash)
                );
                CREATE TABLE nearEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    eventID TEXT NOT NULL, hash TEXT, blockHeight INTEGER NOT NULL, detail BLOB NOT NULL,
                    unresolved INTEGER NOT NULL, PRIMARY KEY(accountID,eventID)
                );
                CREATE INDEX nearEventsHash ON nearEvents(accountID,hash);
                CREATE INDEX nearUnresolvedEvents ON nearEvents(accountID) WHERE unresolved=1;
                CREATE TABLE nearPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["nearSync","nearHoldings","nearHistoryCursors","nearTransactions","nearEvents","nearPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v21_xrpl_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE xrplSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE xrplHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT REFERENCES assets(id), amountAtomic TEXT NOT NULL,
                    signedAmount TEXT NOT NULL,
                    observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX xrplHoldingsAsset ON xrplHoldings(accountID,assetID);
                CREATE TABLE xrplHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    lane TEXT NOT NULL, beforeCursor TEXT, upperLedger INTEGER, oldestLedger INTEGER,
                    stopHash TEXT, headHash TEXT, complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(accountID,lane)
                );
                CREATE TABLE xrplTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    hash TEXT NOT NULL, checkpoint INTEGER NOT NULL, detail BLOB NOT NULL,
                    unresolved INTEGER NOT NULL, PRIMARY KEY(accountID,hash)
                );
                CREATE INDEX xrplUnresolvedTransactions ON xrplTransactions(accountID) WHERE unresolved=1;
                CREATE TABLE xrplPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["xrplSync","xrplHoldings","xrplHistoryCursors","xrplTransactions","xrplPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v22_stellar_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE stellarSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER, failure TEXT, historyFailure TEXT
                );
                CREATE TABLE stellarHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT REFERENCES assets(id), amountAtomic TEXT NOT NULL,
                    observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX stellarHoldingsAsset ON stellarHoldings(accountID,assetID);
                CREATE TABLE stellarHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    lane TEXT NOT NULL, startLedger INTEGER NOT NULL, endLedger INTEGER NOT NULL,
                    cursor TEXT, complete INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(accountID,lane)
                );
                CREATE TABLE stellarEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,id)
                );
                CREATE INDEX stellarEventsTransaction ON stellarEvents(accountID,hash);
                CREATE TABLE stellarTransactions (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    hash TEXT NOT NULL, checkpoint INTEGER NOT NULL, detail BLOB NOT NULL,
                    unresolved INTEGER NOT NULL, PRIMARY KEY(accountID,hash)
                );
                CREATE INDEX stellarUnresolvedTransactions ON stellarTransactions(accountID) WHERE unresolved=1;
                CREATE TABLE stellarPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["stellarEvents","stellarSync","stellarHoldings","stellarHistoryCursors","stellarTransactions","stellarPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v23_robinhood_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE robinhoodSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0, failure TEXT
                );
                CREATE TABLE robinhoodHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT NOT NULL REFERENCES assets(id), detail BLOB NOT NULL,
                    amountAtomic TEXT NOT NULL, observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX robinhoodHoldingsAsset ON robinhoodHoldings(accountID,assetID);
                CREATE TABLE robinhoodHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, startTime DOUBLE NOT NULL, endTime DOUBLE NOT NULL,
                    cursor TEXT, complete INTEGER NOT NULL DEFAULT 0, failure TEXT, PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE robinhoodEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,id)
                );
                CREATE INDEX robinhoodEventsTransaction ON robinhoodEvents(accountID,hash);
                CREATE TABLE robinhoodPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["robinhoodSync","robinhoodHoldings","robinhoodHistoryCursors","robinhoodEvents","robinhoodPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v24_arc_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE arcSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0, failure TEXT
                );
                CREATE TABLE arcHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT NOT NULL REFERENCES assets(id), detail BLOB NOT NULL,
                    amountAtomic TEXT NOT NULL, observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX arcHoldingsAsset ON arcHoldings(accountID,assetID);
                CREATE TABLE arcHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    lane TEXT NOT NULL, startBlock INTEGER NOT NULL, endBlock INTEGER NOT NULL,
                    nextBlock INTEGER NOT NULL, complete INTEGER NOT NULL DEFAULT 0, failure TEXT,
                    PRIMARY KEY(accountID,lane)
                );
                CREATE TABLE arcEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,id)
                );
                CREATE INDEX arcEventsTransaction ON arcEvents(accountID,hash);
                CREATE TABLE arcPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    startBlock INTEGER NOT NULL, endBlock INTEGER NOT NULL, raw BLOB NOT NULL,
                    PRIMARY KEY(accountID,startBlock,endBlock)
                );
                """)
            for table in ["arcSync","arcHoldings","arcHistoryCursors","arcEvents","arcPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v25_wallet_lifecycle") { db in
            try db.execute(sql: """
                ALTER TABLE wallets ADD COLUMN sortOrder INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE wallets ADD COLUMN deletedAt DOUBLE;
                ALTER TABLE wallets ADD COLUMN nameIndex INTEGER NOT NULL DEFAULT 0;
                UPDATE wallets SET sortOrder=(SELECT COUNT(*) FROM wallets w WHERE (w.createdAt,w.id)<(wallets.createdAt,wallets.id));
                UPDATE wallets SET nameIndex=sortOrder;
                CREATE INDEX wallets_order ON wallets(deletedAt,sortOrder,createdAt,id);
                """)
        }
        migrations.registerMigration("v26_transaction_evidence") { db in
            try db.execute(sql: """
                CREATE TABLE transactionEvidence (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    transactionID TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                    conflictKeys BLOB NOT NULL, returnsToWallet INTEGER NOT NULL,
                    outcome TEXT, replacementHash TEXT, outcomeAt DOUBLE,
                    PRIMARY KEY(accountID,transactionID)
                );
                CREATE TABLE transactionConflictKeys (
                    accountID TEXT NOT NULL, transactionID TEXT NOT NULL, conflictKey TEXT NOT NULL,
                    PRIMARY KEY(accountID,transactionID,conflictKey),
                    FOREIGN KEY(accountID,transactionID) REFERENCES transactionEvidence(accountID,transactionID) ON DELETE CASCADE
                );
                CREATE INDEX transaction_conflict_lookup ON transactionConflictKeys(accountID,conflictKey);
                """)
        }
        migrations.registerMigration("v27_history_participants") { db in
            try db.execute(sql: """
                CREATE TABLE transactionParticipants (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    transactionID TEXT NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
                    address TEXT NOT NULL,
                    PRIMARY KEY(accountID,transactionID,address)
                );
                """)
            try OathDatabase.backfillBitcoinParticipants(db)
        }
        migrations.registerMigration("v28_history_safety") { db in
            try HistorySafety.migrate(db)
        }
        migrations.registerMigration("v29_bitcoin_send") { db in
            try db.execute(sql: """
                CREATE TABLE bitcoinSendPlans (
                    sendID TEXT PRIMARY KEY REFERENCES sends(id) ON DELETE CASCADE,
                    plan BLOB NOT NULL
                );
                CREATE TABLE sendDiagnostics (
                    id TEXT PRIMARY KEY NOT NULL, stage TEXT NOT NULL, code TEXT NOT NULL,
                    inputCount INTEGER NOT NULL, appBuild INTEGER NOT NULL, createdAt DOUBLE NOT NULL
                );
                """)
        }
        migrations.registerMigration("v30_bitcoin_cash_send") { db in
            try db.execute(sql: "ALTER TABLE sendDiagnostics ADD COLUMN network TEXT NOT NULL DEFAULT 'bitcoin' CHECK(network IN ('bitcoin','bitcoincash'))")
        }
        migrations.registerMigration("v31_litecoin_send") { db in
            // Rebuild only this outbox to expand its CHECK without altering
            // an already-shipped migration or losing undelivered diagnostics.
            try db.execute(sql: """
                CREATE TABLE sendDiagnostics_v31 (
                    id TEXT PRIMARY KEY NOT NULL, stage TEXT NOT NULL, code TEXT NOT NULL,
                    inputCount INTEGER NOT NULL, appBuild INTEGER NOT NULL, createdAt DOUBLE NOT NULL,
                    network TEXT NOT NULL DEFAULT 'bitcoin' CHECK(network IN ('bitcoin','bitcoincash','litecoin'))
                );
                INSERT INTO sendDiagnostics_v31 SELECT id,stage,code,inputCount,appBuild,createdAt,network FROM sendDiagnostics;
                DROP TABLE sendDiagnostics;
                ALTER TABLE sendDiagnostics_v31 RENAME TO sendDiagnostics;
                """)
        }
        migrations.registerMigration("v32_dogecoin_send") { db in
            // Rebuild only this outbox to expand its CHECK without altering
            // an already-shipped migration or losing undelivered diagnostics.
            try db.execute(sql: """
                CREATE TABLE sendDiagnostics_v32 (
                    id TEXT PRIMARY KEY NOT NULL, stage TEXT NOT NULL, code TEXT NOT NULL,
                    inputCount INTEGER NOT NULL, appBuild INTEGER NOT NULL, createdAt DOUBLE NOT NULL,
                    network TEXT NOT NULL DEFAULT 'bitcoin' CHECK(network IN ('bitcoin','bitcoincash','litecoin','dogecoin'))
                );
                INSERT INTO sendDiagnostics_v32 SELECT id,stage,code,inputCount,appBuild,createdAt,network FROM sendDiagnostics;
                DROP TABLE sendDiagnostics;
                ALTER TABLE sendDiagnostics_v32 RENAME TO sendDiagnostics;
                """)
        }
        migrations.registerMigration("v33_post_send_balance_refresh") { db in
            try db.execute(sql: """
                CREATE TABLE sendBalanceRefreshes (
                    sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE,
                    completedAt DOUBLE
                );
                INSERT INTO sendBalanceRefreshes(sendID) SELECT id FROM sends WHERE state='broadcast';
                """)
        }
        migrations.registerMigration("v34_sui_send") { db in
            try db.execute(sql: "CREATE TABLE suiSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL)")
        }
        migrations.registerMigration("v35_xrpl_send") { db in
            try db.execute(sql: "CREATE TABLE xrplSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL)")
        }
        migrations.registerMigration("v36_stellar_send") { db in
            try db.execute(sql: "CREATE TABLE stellarSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL)")
        }
        migrations.registerMigration("v37_tron_send") { db in
            try db.execute(sql: "CREATE TABLE tronSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL)")
        }
        migrations.registerMigration("v38_near_send") { db in
            try db.execute(sql: "CREATE TABLE nearSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL)")
        }
        migrations.registerMigration("v39_tron_submission_acknowledgement") { db in
            // Broadcast state alone only proves an attempt. Preserve positive
            // network acceptance separately, without marking execution final.
            try db.execute(sql: "ALTER TABLE tronSendPlans ADD COLUMN submittedAt DOUBLE")
        }
        migrations.registerMigration("v40_send_status_tracking") { db in
            try db.execute(sql: """
                CREATE TABLE sendStatusChecks (
                    sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE,
                    nextAttemptAt DOUBLE NOT NULL DEFAULT 0,
                    attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts>=0),
                    lastCheckedAt DOUBLE,
                    leaseToken TEXT, leaseOwner TEXT, leaseUntil DOUBLE,
                    availableAt DOUBLE GENERATED ALWAYS AS (MAX(nextAttemptAt,COALESCE(leaseUntil,0))) STORED
                );
                CREATE INDEX send_status_due ON sendStatusChecks(availableAt,sendID);
                INSERT INTO sendStatusChecks(sendID) SELECT id FROM sends WHERE state IN ('signed','broadcast');
                CREATE TRIGGER send_status_insert AFTER INSERT ON sends
                WHEN NEW.state IN ('signed','broadcast') BEGIN
                    INSERT OR IGNORE INTO sendStatusChecks(sendID) VALUES(NEW.id);
                END;
                CREATE TRIGGER send_status_pending AFTER UPDATE OF state ON sends
                WHEN NEW.state IN ('signed','broadcast') BEGIN
                    INSERT OR IGNORE INTO sendStatusChecks(sendID) VALUES(NEW.id);
                END;
                CREATE TRIGGER send_status_terminal AFTER UPDATE OF state ON sends
                WHEN NEW.state IN ('confirmed','failed','cancelled') BEGIN
                    DELETE FROM sendStatusChecks WHERE sendID=NEW.id;
                END;
                CREATE TRIGGER send_status_reorg AFTER UPDATE OF state ON transactions
                WHEN OLD.state='confirmed' AND NEW.state IN ('pending','reorged') BEGIN
                    UPDATE sends SET state='broadcast',updatedAt=NEW.updatedAt
                    WHERE transactionID=NEW.id AND state='confirmed';
                END;
                """)
        }
        migrations.registerMigration("v41_aptos_send") { db in
            try db.execute(sql: "CREATE TABLE aptosSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL, submittedAt DOUBLE)")
        }
        migrations.registerMigration("v42_ton_send") { db in
            try db.execute(sql: "CREATE TABLE tonSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL, submittedAt DOUBLE, transactionHash TEXT, messageHash TEXT)")
            try db.execute(sql: "CREATE UNIQUE INDEX tonSendPlans_transaction ON tonSendPlans(transactionHash) WHERE transactionHash IS NOT NULL")
            try db.execute(sql: "CREATE UNIQUE INDEX tonSendPlans_message ON tonSendPlans(messageHash) WHERE messageHash IS NOT NULL")
        }
        migrations.registerMigration("v43_solana_send") { db in
            try db.execute(sql: "CREATE TABLE solanaSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL, submittedAt DOUBLE)")
            try db.execute(sql: "CREATE INDEX sends_active_source ON sends(networkID,senderAddress) WHERE state IN ('queued','signed','broadcast')")
        }
        migrations.registerMigration("v44_arc_send") { db in
            try db.execute(sql: "CREATE TABLE arcSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL, submittedAt DOUBLE)")
        }

        migrations.registerMigration("v45_hyperevm_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE hyperevmSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0, failure TEXT
                );
                CREATE TABLE hyperevmHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT NOT NULL REFERENCES assets(id), detail BLOB NOT NULL,
                    amountAtomic TEXT NOT NULL, observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX hyperevmHoldingsAsset ON hyperevmHoldings(accountID,assetID);
                CREATE TABLE hyperevmHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, startTime DOUBLE NOT NULL, endTime DOUBLE NOT NULL,
                    cursor TEXT, complete INTEGER NOT NULL DEFAULT 0, failure TEXT, PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE hyperevmEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,id)
                );
                CREATE INDEX hyperevmEventsTransaction ON hyperevmEvents(accountID,hash);
                CREATE TABLE hyperevmPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["hyperevmSync","hyperevmHoldings","hyperevmHistoryCursors","hyperevmEvents","hyperevmPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER trust_hyperevmHoldings_\(operation) AFTER \(operation) ON hyperevmHoldings WHEN NEW.verified=1
                    BEGIN
                        INSERT INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt)
                        SELECT networkID,reference,'verified.hyperevmHoldings',decimals,NEW.observedAt FROM assets
                        WHERE id=NEW.assetID AND reference<>'native'
                        ON CONFLICT(networkID,reference,source) DO UPDATE SET
                            decimals=excluded.decimals,observedAt=excluded.observedAt
                        WHERE excluded.observedAt>=tokenHistoryTrust.observedAt;
                    END;
                    """)
            }

        }
        migrations.registerMigration("v46_indexed_evm_ledger") { db in
            try db.execute(sql: """
                CREATE TABLE indexedEVMSync (
                    accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, inventory BLOB, observedAt DOUBLE, checkpoint INTEGER,
                    complete INTEGER NOT NULL DEFAULT 0, failure TEXT
                );
                CREATE TABLE indexedEVMHoldings (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    reference TEXT NOT NULL, assetID TEXT NOT NULL REFERENCES assets(id), detail BLOB NOT NULL,
                    amountAtomic TEXT NOT NULL, observedAt DOUBLE NOT NULL, checkpoint INTEGER NOT NULL,
                    verified INTEGER NOT NULL CHECK(verified IN (0,1)), PRIMARY KEY(accountID,reference)
                );
                CREATE INDEX indexedEVMHoldingsAsset ON indexedEVMHoldings(accountID,assetID);
                CREATE TABLE indexedEVMHistoryCursors (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL, startTime DOUBLE NOT NULL, endTime DOUBLE NOT NULL,
                    cursor TEXT, complete INTEGER NOT NULL DEFAULT 0, failure TEXT, PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE indexedEVMEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    id TEXT NOT NULL, hash TEXT NOT NULL, detail BLOB NOT NULL, PRIMARY KEY(accountID,id)
                );
                CREATE INDEX indexedEVMEventsTransaction ON indexedEVMEvents(accountID,hash);
                CREATE TABLE indexedEVMPages (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    pageKey TEXT NOT NULL, raw BLOB NOT NULL, PRIMARY KEY(accountID,pageKey)
                );
                """)
            for table in ["indexedEVMSync","indexedEVMHoldings","indexedEVMHistoryCursors","indexedEVMEvents","indexedEVMPages"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER trust_indexedEVMHoldings_\(operation) AFTER \(operation) ON indexedEVMHoldings WHEN NEW.verified=1
                    BEGIN
                        INSERT INTO tokenHistoryTrust(networkID,reference,source,decimals,observedAt)
                        SELECT networkID,reference,'verified.indexedEVMHoldings',decimals,NEW.observedAt FROM assets
                        WHERE id=NEW.assetID AND reference<>'native'
                        ON CONFLICT(networkID,reference,source) DO UPDATE SET
                            decimals=excluded.decimals,observedAt=excluded.observedAt
                        WHERE excluded.observedAt>=tokenHistoryTrust.observedAt;
                    END;
                    """)
            }

        }
        migrations.registerMigration("v47_send_status_available_at") { db in
            // Some installations already recorded v40 before availableAt was
            // added to its CREATE TABLE. Never rerun/edit an applied migration
            // or reset the journal to repair an upgrade.
            // table_info omits generated columns; table_xinfo sees both forms.
            let columns = try Row.fetchAll(db, sql: "PRAGMA table_xinfo(sendStatusChecks)")
            if !columns.contains(where: { ($0["name"] as String) == "availableAt" }) {
                // SQLite cannot ADD a STORED generated column to an existing
                // table. Its indexed VIRTUAL equivalent preserves every queue
                // row, lease, trigger and foreign key without a table rebuild.
                try db.execute(sql: """
                    ALTER TABLE sendStatusChecks ADD COLUMN availableAt DOUBLE
                    GENERATED ALWAYS AS (MAX(nextAttemptAt,COALESCE(leaseUntil,0))) VIRTUAL
                    """)
            }
            // Older v40 indexes covered nextAttemptAt alone. The query requires
            // the effective deadline including leases, plus its stable tie break.
            try db.execute(sql: """
                DROP INDEX IF EXISTS send_status_due;
                CREATE INDEX send_status_due ON sendStatusChecks(availableAt,sendID);
                """)
        }
        migrations.registerMigration("v48_evm_send") { db in
            try db.execute(sql: "CREATE TABLE evmSendPlans (sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE, plan BLOB NOT NULL, submittedAt DOUBLE)")
            // Replace the local pending row when a real indexed transfer arrives.
            // Preserve the durable send and every distinct provider event.
            for operation in ["INSERT","UPDATE"] {
                try db.execute(sql:"""
                    CREATE TRIGGER evm_send_activity_\(operation) AFTER \(operation) ON activity
                    WHEN NEW.direction='outgoing'
                    BEGIN
                        DELETE FROM activity WHERE id<>NEW.id AND id IN (
                            SELECT s.accountID||':'||t.hash||':'||a.reference
                            FROM sends s JOIN evmSendPlans p ON p.sendID=s.id
                            JOIN transactions t ON t.id=s.transactionID JOIN assets a ON a.id=s.assetID
                            WHERE s.accountID=NEW.accountID AND s.transactionID=NEW.transactionID
                            AND s.assetID=NEW.assetID AND lower(s.recipient)=lower(NEW.counterparty)
                        );
                    END;
                    """)
            }
            for operation in ["INSERT","UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_evmSendPlans_\(operation) BEFORE \(operation) ON evmSendPlans
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
        migrations.registerMigration("v49_balance_snapshots") { db in
            try db.execute(sql: """
                CREATE TABLE balanceSnapshots (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    eventID TEXT NOT NULL UNIQUE,
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    currency TEXT NOT NULL CHECK(length(currency)=3 AND currency NOT GLOB '*[^A-Z]*'),
                    amount TEXT NOT NULL,
                    valuationComplete INTEGER NOT NULL CHECK(valuationComplete IN (0,1)),
                    recordedAt DOUBLE NOT NULL CHECK(recordedAt>=0),
                    reason TEXT NOT NULL CHECK(reason IN ('homeVisit','appOpen','refresh','balanceUpdate'))
                );
                CREATE INDEX balance_snapshots_day ON balanceSnapshots(walletID,currency,recordedAt,id);
                CREATE INDEX balance_snapshots_complete_day ON balanceSnapshots(walletID,currency,recordedAt,id)
                    WHERE valuationComplete=1;
                """)
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_balanceSnapshots_\(operation) BEFORE \(operation) ON balanceSnapshots
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
        migrations.registerMigration("v50_permissions") { db in
            try db.execute(sql: """
                CREATE TABLE permissionScans (
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    owner TEXT NOT NULL, scan BLOB NOT NULL, PRIMARY KEY(accountID,owner)
                );
                CREATE INDEX permission_scans_wallet ON permissionScans(walletID);
                CREATE TABLE permissionRemovals (
                    sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE,
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    networkID TEXT NOT NULL, owner TEXT NOT NULL, revocation BLOB NOT NULL,
                    status TEXT NOT NULL CHECK(status IN ('pending','removed','active')), checkedAt DOUBLE
                );
                CREATE INDEX permission_removals_wallet ON permissionRemovals(walletID);
                CREATE TRIGGER permission_reorg AFTER UPDATE OF state ON sends
                WHEN OLD.state='confirmed' AND NEW.state='broadcast' BEGIN
                    UPDATE permissionRemovals SET status='pending',checkedAt=NULL WHERE sendID=NEW.id;
                END;
                DROP TRIGGER send_status_terminal;
                CREATE TRIGGER send_status_terminal AFTER UPDATE OF state ON sends
                WHEN NEW.state NOT IN ('signed','broadcast')
                    AND NOT (NEW.state='confirmed' AND EXISTS(SELECT 1 FROM permissionRemovals WHERE sendID=NEW.id AND status='pending'))
                BEGIN DELETE FROM sendStatusChecks WHERE sendID=NEW.id; END;
                """)
            for table in ["permissionScans","permissionRemovals"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql: """
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v51_async_send_acknowledgements") { db in
            for table in ["stellarSendPlans","xrplSendPlans","nearSendPlans"] {
                try db.execute(sql:"ALTER TABLE \(table) ADD COLUMN submittedAt DOUBLE")
            }
        }
        migrations.registerMigration("v52_thorchain") { db in
            try db.execute(sql:"""
                CREATE TABLE thorchainSync (
                    accountID TEXT PRIMARY KEY NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    runID TEXT NOT NULL, observedAt DOUBLE, inventory BLOB
                );
                CREATE TABLE thorchainHistory (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    stream TEXT NOT NULL, lane TEXT NOT NULL,
                    height INTEGER NOT NULL, lowerHeight INTEGER NOT NULL,
                    page INTEGER NOT NULL CHECK(page>0), complete INTEGER NOT NULL CHECK(complete IN (0,1)),
                    PRIMARY KEY(accountID,stream,lane)
                );
                CREATE TABLE thorchainPendingEvents (
                    accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                    eventID TEXT NOT NULL, reference TEXT NOT NULL, payload BLOB NOT NULL,
                    PRIMARY KEY(accountID,eventID)
                );
                """)
            for table in ["thorchainSync","thorchainHistory","thorchainPendingEvents"] {
                for operation in ["INSERT","UPDATE"] {
                    try db.execute(sql:"""
                        CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                        WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                        BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                        """)
                }
            }
        }
        migrations.registerMigration("v53_thorchain_sending") { db in
            try db.execute(sql:"ALTER TABLE thorchainSync ADD COLUMN height INTEGER")
            try db.execute(sql:"CREATE TABLE thorchainSendPlans(sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE,plan BLOB NOT NULL,submittedAt DOUBLE)")
            for operation in ["INSERT","UPDATE"] {
                try db.execute(sql:"""
                    CREATE TRIGGER reset_guard_thorchainSendPlans_\(operation) BEFORE \(operation) ON thorchainSendPlans
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
        migrations.registerMigration("v54_balance_snapshot_baselines") { db in
            try db.execute(sql: """
                ALTER TABLE balanceSnapshots ADD COLUMN comparisonReady INTEGER NOT NULL DEFAULT 0 CHECK(comparisonReady IN (0,1));
                ALTER TABLE balanceSnapshots ADD COLUMN holdingsJSON BLOB;
                UPDATE balanceSnapshots SET comparisonReady=1 WHERE valuationComplete=1
                    AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset');
                DROP INDEX balance_snapshots_complete_day;
                CREATE INDEX balance_snapshots_comparison_day ON balanceSnapshots(walletID,currency,recordedAt,id)
                    WHERE comparisonReady=1;
                CREATE INDEX balance_snapshots_retention ON balanceSnapshots(recordedAt);
                """)
        }
        migrations.registerMigration("v55_wallet_portfolio_filters") { db in
            try db.execute(sql: """
                CREATE TABLE walletPortfolioFilters (
                    walletID TEXT PRIMARY KEY NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    selection BLOB NOT NULL,
                    hidesUnverifiedTokens INTEGER NOT NULL DEFAULT 1 CHECK(hidesUnverifiedTokens IN (0,1))
                );
                DROP VIEW visibleActivity;
                CREATE VIEW visibleActivity AS
                SELECT a.* FROM activity a JOIN assets s ON s.id=a.assetID
                WHERE NOT oath_phishing_metadata(s.name,s.symbol)
                AND NOT EXISTS(SELECT 1 FROM tokenHistoryBlocks b WHERE b.networkID=s.networkID AND b.reference=s.reference)
                AND (s.reference='native'
                    OR EXISTS(SELECT 1 FROM walletPortfolioFilters f WHERE f.walletID=a.walletID AND f.hidesUnverifiedTokens=0)
                    OR EXISTS(SELECT 1 FROM trackedAssets tr WHERE tr.accountID=a.accountID AND tr.assetID=a.assetID)
                    OR EXISTS(SELECT 1 FROM tokenHistoryTrust v WHERE v.networkID=s.networkID AND v.reference=s.reference
                        AND (v.decimals IS NULL OR v.decimals=s.decimals)))
                AND (a.amountAtomic<>'0' OR
                    (s.reference='native' AND a.direction IN ('outgoing','self')) OR
                    (a.direction IN ('outgoing','self') AND EXISTS(SELECT 1 FROM transactions t
                        LEFT JOIN transactionEvidence e ON e.transactionID=t.id AND e.accountID=a.accountID
                        WHERE t.id=a.transactionID AND COALESCE(e.outcome,t.state) IN ('failed','canceled','replaced','reorged'))));
                """)
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_walletPortfolioFilters_\(operation) BEFORE \(operation) ON walletPortfolioFilters
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
        migrations.registerMigration("v56_wallet_default_names") { db in
            try db.execute(sql: "ALTER TABLE wallets ADD COLUMN nameGroup TEXT")
            // Stable creation order, independent of the current sidebar order.
            // Existing custom labels remain untouched.
            var next: [String: Int] = [:]
            for wallet in try WalletRecord.fetchAll(db, sql: "SELECT * FROM wallets WHERE NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY nameIndex,createdAt,id") {
                let networks = try String.fetchAll(db, sql: "SELECT networkID FROM accounts WHERE walletID=?", arguments: [wallet.id])
                let group = WalletRecord.inferredNameGroup(kind: wallet.kind, networkIDs: networks)
                let index = next[group, default: 0]
                try db.execute(sql: "UPDATE wallets SET nameGroup=?,nameIndex=? WHERE id=?", arguments: [group, index, wallet.id])
                next[group] = index + 1
            }
            try db.execute(sql: "CREATE INDEX wallets_name_group ON wallets(nameGroup,nameIndex)")
        }
        migrations.registerMigration("v57_contract_identity_cache") { db in
            try db.execute(sql: """
                CREATE TABLE contractIdentities (
                    network TEXT NOT NULL, address TEXT NOT NULL, identity BLOB NOT NULL,
                    checkedAt REAL NOT NULL, PRIMARY KEY(network,address)
                );
                CREATE INDEX contract_identity_age ON contractIdentities(checkedAt);
                """)
        }
        migrations.registerMigration("v58_home_read_indexes") { db in
            try HomeReadIndex.migrate(db)
        }
        migrations.registerMigration("v59_permission_batches") { db in
            try OathDatabase.migratePermissionBatches(db)
        }
        migrations.registerMigration("v60_walletconnect_solana") { db in
            try OathDatabase.migrateWalletConnectSolana(db)
        }
        // Retired migration identifiers remain registered so existing wallets upgrade safely.
        migrations.registerMigration("v61_notification_registration") { _ in }
        migrations.registerMigration("v62_aptos_receipt_participants") { db in
            // Older index pages retained only the selected account's events.
            // Keep the public ledger available offline while the existing
            // background synchronizer replenishes peer ownership once.
            try db.execute(sql: """
                UPDATE aptosHistoryCursors
                SET beforeVersion=NULL, stopVersion=NULL, headVersion=NULL, complete=0
                WHERE EXISTS (SELECT 1 FROM aptosTransactions t
                              WHERE t.accountID=aptosHistoryCursors.accountID)
                """)
        }
        migrations.registerMigration("v63_notification_external_submissions") { _ in }
        migrations.registerMigration("v64_remove_obsolete_delivery_state") { db in
            // Remove only the retired push-delivery objects. The send journal,
            // WalletConnect submissions and transaction history remain intact.
            try db.execute(sql: """
                DROP TRIGGER IF EXISTS notification_send_insert;
                DROP TRIGGER IF EXISTS notification_send_update;
                DROP TABLE IF EXISTS notificationRegistrationOutbox;
                DROP INDEX IF EXISTS wc_solana_notification_pending;
                DELETE FROM settings WHERE key GLOB 'notifications.*';
                """)
            if try db.columns(in: "walletConnectSolanaSubmissions").contains(where: { $0.name == "notificationRegistered" }) {
                try db.execute(sql: "ALTER TABLE walletConnectSolanaSubmissions DROP COLUMN notificationRegistered")
            }
        }
        migrations.registerMigration("v65_receive_qr_cache") { db in
            try OathDatabase.migrateReceiveQRCodes(db)
        }
        migrations.registerMigration("v66_asset_visibility_and_shared_tracking") { db in
            try OathDatabase.migrateAssetVisibility(db)
        }
        migrations.registerMigration("v67_wallet_scoped_token_tracking") { db in
            // Existing per-account selections have no original-wallet provenance.
            // Preserve them and wallet-specific visibility; stop future sharing.
            try db.execute(sql: """
                DROP TRIGGER IF EXISTS track_shared_assets_on_account_insert;
                DROP TABLE IF EXISTS sharedTrackedAssets;
                """)
        }
        migrations.registerMigration("v68_stablecoin_restriction_checks") { db in
            try db.execute(sql: """
                CREATE TABLE stablecoinSecurityChecks (
                    walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    probeID TEXT NOT NULL, networkID TEXT NOT NULL, reference TEXT NOT NULL,
                    outcome TEXT NOT NULL CHECK (outcome IN ('restricted','notDetected','unavailable')),
                    PRIMARY KEY(walletID, probeID)
                );
                CREATE TABLE stablecoinSecurityNotices (
                    walletID TEXT PRIMARY KEY NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    acknowledged INTEGER NOT NULL DEFAULT 0
                );
                """)
        }
        migrations.registerMigration("v69_passphrase_wallet_families") { db in
            try db.execute(sql: "ALTER TABLE wallets ADD COLUMN parentWalletID TEXT")
            // Parent provenance is recovered only after the vault is unlocked.
            // Preserve custom labels and every wallet's independent identity.
            let ids = try String.fetchAll(db, sql: "SELECT id FROM wallets WHERE kind='passphrase' AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY createdAt,id")
            for (offset, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE wallets SET nameGroup='passphrase',nameIndex=? WHERE id=?", arguments: [offset + 1, id])
            }
        }
        migrations.registerMigration("v70_confirmed_wallet_names") { db in
            try db.execute(sql: "ALTER TABLE wallets ADD COLUMN confirmedName TEXT")
        }
        migrations.registerMigration("v71_bitcoin_submission_acknowledgement") { db in
            try db.execute(sql: "ALTER TABLE bitcoinSendPlans ADD COLUMN submittedAt DOUBLE")
        }
        migrations.registerMigration("v72_live_send_balance_refresh") { db in
            try db.execute(sql: """
                ALTER TABLE sendBalanceRefreshes ADD COLUMN revision INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE sendBalanceRefreshSignal (id INTEGER PRIMARY KEY CHECK(id=1), revision INTEGER NOT NULL);
                INSERT INTO sendBalanceRefreshSignal VALUES(1,0);
                CREATE TRIGGER send_balance_refresh_insert AFTER INSERT ON sendBalanceRefreshes BEGIN
                    UPDATE sendBalanceRefreshSignal SET revision=revision+1 WHERE id=1;
                    UPDATE sendBalanceRefreshes SET revision=(SELECT revision FROM sendBalanceRefreshSignal WHERE id=1) WHERE sendID=NEW.sendID;
                END;
                CREATE TRIGGER send_balance_refresh_requeue AFTER UPDATE OF completedAt ON sendBalanceRefreshes
                WHEN NEW.completedAt IS NULL BEGIN
                    UPDATE sendBalanceRefreshSignal SET revision=revision+1 WHERE id=1;
                    UPDATE sendBalanceRefreshes SET revision=(SELECT revision FROM sendBalanceRefreshSignal WHERE id=1) WHERE sendID=NEW.sendID;
                END;
                CREATE TRIGGER send_balance_refresh_state AFTER UPDATE OF state ON sends
                WHEN NEW.state<>OLD.state AND NEW.signedPayload IS NOT NULL AND NEW.state IN ('broadcast','confirmed','failed','cancelled') BEGIN
                    INSERT INTO sendBalanceRefreshes(sendID) VALUES(NEW.id) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL;
                END;
                """)
            // A background broadcaster can acknowledge a send after the UI's
            // initial retry burst. Wake on the first acknowledgement only.
            for table in ["bitcoinSendPlans", "evmSendPlans", "arcSendPlans", "aptosSendPlans", "tonSendPlans", "solanaSendPlans", "tronSendPlans", "nearSendPlans", "stellarSendPlans", "xrplSendPlans", "thorchainSendPlans"] {
                try db.execute(sql: """
                    CREATE TRIGGER send_balance_ack_\(table) AFTER UPDATE OF submittedAt ON \(table)
                    WHEN OLD.submittedAt IS NULL AND NEW.submittedAt IS NOT NULL BEGIN
                        INSERT INTO sendBalanceRefreshes(sendID) VALUES(NEW.sendID) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL;
                    END;
                    """)
            }
        }
        migrations.registerMigration("v73_evm_swap_history") { db in
            try OathDatabase.installSwapHistory(db)
        }
        migrations.registerMigration("v74_evm_bridge_history") { db in
            try OathDatabase.installBridgeHistory(db)
        }
        migrations.registerMigration("v75_relay_fill_request_identity") { db in
            // Upgrade projections without deleting raw transfers or cached RPC evidence.
            // The normal enrichment worker reclassifies version-2 evidence locally.
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                guard let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name=?", arguments: [name]) else {
                    throw StoreError.invalidValue("missing history projection")
                }
                try db.execute(sql: "DROP VIEW \(name)")
                try db.execute(sql: sql.replacingOccurrences(of: "c.version=2", with: "c.version=3"))
            }
        }
        migrations.registerMigration("v76_evm_contract_history_titles") { db in
            try db.execute(sql: "ALTER TABLE evmHistorySwaps ADD COLUMN contractKind TEXT")
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                guard let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name=?", arguments: [name]) else {
                    throw StoreError.invalidValue("missing history projection")
                }
                try db.execute(sql: "DROP VIEW \(name)")
                try db.execute(sql: sql.replacingOccurrences(of: "c.version=3", with: "c.version=4"))
            }
        }
        migrations.registerMigration("v77_preserve_evm_history_receipts") { db in
            try OathDatabase.repairEVMHistoryReceiptReferences(db)
        }
        migrations.registerMigration("v78_balance_currency_basis") { db in
            try OathDatabase.installBalanceCurrencyBasis(db)
        }
        migrations.registerMigration("v79_universal_router_history") { db in
            // Existing positive classifications remain valid while cached
            // negative results are reconsidered by the enrichment worker.
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                guard let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name=?", arguments: [name]) else {
                    throw StoreError.invalidValue("missing history projection")
                }
                try db.execute(sql: "DROP VIEW \(name)")
                try db.execute(sql: sql.replacingOccurrences(of: "c.version=4", with: "c.version IN (4,5)"))
            }
        }
        migrations.registerMigration("v80_native_history_execution") { db in
            for name in ["validHistorySwaps", "validHistoryBridges"] {
                guard let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name=?", arguments: [name]) else {
                    throw StoreError.invalidValue("missing history projection")
                }
                try db.execute(sql: "DROP VIEW \(name)")
                try db.execute(sql: sql.replacingOccurrences(of: "c.version IN (4,5)", with: "c.version IN (4,5,6)"))
            }
        }
        migrations.registerMigration("v81_polkadot") { db in
            try db.execute(sql: """
                CREATE TABLE polkadotSync(accountID TEXT PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,runID TEXT NOT NULL,height INTEGER,observedAt DOUBLE,inventory BLOB);
                CREATE TABLE polkadotHoldings(accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,reference TEXT NOT NULL,assetID TEXT NOT NULL REFERENCES assets(id),amountAtomic TEXT NOT NULL,observedAt DOUBLE NOT NULL,checkpoint INTEGER NOT NULL,verified INTEGER NOT NULL CHECK(verified IN(0,1)),PRIMARY KEY(accountID,reference));
                CREATE INDEX polkadotHoldingAsset ON polkadotHoldings(accountID,assetID);
                CREATE TABLE polkadotHistory(accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,stream TEXT NOT NULL,page INTEGER NOT NULL,upperHeight INTEGER NOT NULL,lowerHeight INTEGER NOT NULL,observedHeight INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(accountID,stream));
                CREATE TABLE polkadotEvents(accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,id TEXT NOT NULL,transactionID TEXT NOT NULL,detail BLOB NOT NULL,PRIMARY KEY(accountID,id));
                CREATE INDEX polkadotEventTransaction ON polkadotEvents(accountID,transactionID);
                """)
            for table in ["polkadotSync", "polkadotHoldings", "polkadotHistory", "polkadotEvents"] {
                for operation in ["INSERT", "UPDATE"] {
                    try db.execute(sql: "CREATE TRIGGER \(table)_reset_\(operation.lowercased()) BEFORE \(operation) ON \(table) WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') BEGIN SELECT RAISE(ABORT,'wallet reset pending'); END")
                }
            }
        }
        migrations.registerMigration("v82_polkadot_send") { db in
            try db.execute(sql:"CREATE TABLE polkadotSendPlans(sendID TEXT PRIMARY KEY NOT NULL REFERENCES sends(id) ON DELETE CASCADE,plan BLOB NOT NULL,submittedAt DOUBLE)")
            try db.execute(sql:"""
                CREATE TRIGGER send_balance_ack_polkadotSendPlans AFTER UPDATE OF submittedAt ON polkadotSendPlans
                WHEN OLD.submittedAt IS NULL AND NEW.submittedAt IS NOT NULL BEGIN
                    INSERT INTO sendBalanceRefreshes(sendID) VALUES(NEW.sendID) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL;
                END;
                """)
            for operation in ["INSERT","UPDATE"] {
                try db.execute(sql:"CREATE TRIGGER polkadotSendPlans_reset_\(operation.lowercased()) BEFORE \(operation) ON polkadotSendPlans WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') BEGIN SELECT RAISE(ABORT,'wallet reset pending'); END")
            }
        }
        migrations.registerMigration("v83_polkadot_send_history_identity") { db in
            try db.execute(sql:"ALTER TABLE polkadotSendPlans ADD COLUMN ledgerID TEXT")
            try db.execute(sql:"CREATE INDEX polkadotSendLedgerIdentity ON polkadotSendPlans(ledgerID)")
        }
        migrations.registerMigration("v84_walletconnect_ton") { db in
            try OathDatabase.migrateWalletConnectTon(db)
        }
        migrations.registerMigration("v85_walletconnect_bitcoin") { db in
            try OathDatabase.migrateWalletConnectBitcoin(db)
        }
        migrations.registerMigration("v86_walletconnect_sui") { db in
            try OathDatabase.migrateWalletConnectSui(db)
        }
        migrations.registerMigration("v87_walletconnect_near") { db in
            try OathDatabase.migrateWalletConnectNear(db)
        }
        migrations.registerMigration("v88_walletconnect_stellar") { db in
            try OathDatabase.migrateWalletConnectStellar(db)
        }
        migrations.registerMigration("v89_walletconnect_xrpl") { db in
            try OathDatabase.migrateWalletConnectXrpl(db)
        }
        migrations.registerMigration("v90_litecoin_history_destinations") { db in
            try OathDatabase.clearInvalidLitecoinHistoryAddresses(db)
        }
        migrations.registerMigration("v101_store_account_compatibility", foreignKeyChecks: .immediate) { db in
            try LegacyAccountDirectory.install(db)
        }
        return migrations
    }
}
