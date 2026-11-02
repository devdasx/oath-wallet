import GRDB

/// 4.1.2 queries the physical `accounts` table and rejects an entire wallet
/// if even one returned network cannot be decoded. Keep that table writable
/// for the older binary. All current activity and child FKs use walletAccounts.
enum LegacyAccountDirectory {
    // Frozen catalogue from the 4.1.2 preparation source. Never expand it when
    // enrolling a new chain. These are source constants, not user input.
    private static let networks = """
        'aptos','arbitrum','arc','avalanche','base','bitcoin','bitcoincash','bnb','dogecoin',
        'ethereum','fantom','flare','gnosis','hyperevm','celo','monad','unichain','linea','litecoin',
        'near','optimism','polygon','robinhood','scroll','solana','somnia','story',
        'stellar','sui','taiko','telos','thorchain','ton','tron','xlayer','xrpl'
        """
    private static let columns = ["id", "walletID", "networkID", "address", "derivationPath", "accountIndex", "syncGeneration"]

    static func install(_ db: Database) throws {
        // Rename in place: no account or dependent row is removed/reinserted.
        // Modern SQLite redirects pre-existing FKs, indexes, triggers and views
        // to the renamed parent. GRDB runs the entire migration atomically.
        let names = columns.joined(separator: ", ")
        let values = columns.map { "NEW." + $0 }.joined(separator: ", ")
        let sameNew = columns.map { "\($0) IS NEW.\($0)" }.joined(separator: " AND ")
        let sameOld = columns.map { "\($0) IS OLD.\($0)" }.joined(separator: " AND ")
        let assignments = columns.map { "\($0) = NEW.\($0)" }.joined(separator: ", ")
        let visible = "NEW.networkID IN (\(networks))"
        let legacyAlter = try Bool.fetchOne(db, sql: "PRAGMA legacy_alter_table") == true
        try db.execute(sql: "PRAGMA legacy_alter_table = OFF")
        defer { if legacyAlter { try? db.execute(sql: "PRAGMA legacy_alter_table = ON") } }
        try db.execute(sql: "ALTER TABLE accounts RENAME TO walletAccounts")
        // Refuse to commit if an SQLite build failed to retarget a dependent
        // ledger. Its existing data must never end up linked to the filtered copy.
        guard try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM sqlite_master t JOIN pragma_foreign_key_list(t.name) fk
            WHERE t.type='table' AND lower(fk."table")='accounts'
            """) == 0 else { throw StoreError.invalidTransition }
        try db.execute(sql: """
            CREATE TABLE accounts (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                networkID TEXT NOT NULL REFERENCES networks(id) CHECK(networkID IN (\(networks))),
                address TEXT NOT NULL, derivationPath TEXT NOT NULL,
                accountIndex INTEGER NOT NULL CHECK(accountIndex >= 0), syncGeneration INTEGER NOT NULL DEFAULT 0,
                UNIQUE(walletID, networkID, address), UNIQUE(id, networkID), UNIQUE(id, walletID)
            );
            CREATE INDEX legacy_accounts_wallet_network ON accounts(walletID,networkID,id);
            CREATE INDEX legacy_accounts_network_address ON accounts(networkID,address);
            INSERT INTO accounts (\(names)) SELECT \(names) FROM walletAccounts WHERE networkID IN (\(networks));

            CREATE TRIGGER legacy_directory_insert AFTER INSERT ON walletAccounts
            WHEN \(visible) AND NOT EXISTS (SELECT 1 FROM accounts WHERE \(sameNew))
            BEGIN
                INSERT INTO accounts (\(names)) VALUES (\(values));
            END;

            CREATE TRIGGER legacy_directory_update AFTER UPDATE ON walletAccounts
            BEGIN
                DELETE FROM accounts WHERE id=OLD.id AND (OLD.id IS NOT NEW.id OR NOT (\(visible)));
                UPDATE accounts SET \(assignments) WHERE id=NEW.id AND \(visible) AND NOT (\(sameNew));
                INSERT INTO accounts (\(names)) SELECT \(values)
                    WHERE \(visible) AND NOT EXISTS (SELECT 1 FROM accounts WHERE id=NEW.id);
            END;

            CREATE TRIGGER legacy_directory_delete AFTER DELETE ON walletAccounts
            BEGIN DELETE FROM accounts WHERE id=OLD.id; END;

            -- Matching-row guards stop feedback even with recursive_triggers
            -- enabled. Old builds' normal inserts, updates and deletes must
            -- also run the original constraints and triggers on walletAccounts.
            CREATE TRIGGER legacy_writer_insert AFTER INSERT ON accounts
            WHEN NOT EXISTS (SELECT 1 FROM walletAccounts WHERE \(sameNew))
            BEGIN
                SELECT CASE WHEN EXISTS (SELECT 1 FROM walletAccounts WHERE id=NEW.id)
                    THEN RAISE(ABORT, 'account identity conflict') END;
                INSERT INTO walletAccounts (\(names)) VALUES (\(values));
            END;
            CREATE TRIGGER legacy_writer_update AFTER UPDATE ON accounts
            WHEN EXISTS (SELECT 1 FROM walletAccounts WHERE \(sameOld))
            BEGIN
                UPDATE walletAccounts SET \(assignments) WHERE id=OLD.id;
            END;
            -- A parent wallet deletion already cascades through the original
            -- foreign keys. Let SQLite preserve their original deletion order.
            CREATE TRIGGER legacy_writer_delete AFTER DELETE ON accounts
            WHEN EXISTS (SELECT 1 FROM wallets WHERE id=OLD.walletID)
                AND EXISTS (SELECT 1 FROM walletAccounts WHERE \(sameOld))
            BEGIN DELETE FROM walletAccounts WHERE id=OLD.id; END;
            """)
    }
}
