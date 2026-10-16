import GRDB

/// Durable SQLite projections, maintained in the SAME transaction as their
/// sources. No polling, delayed indexing, second database, or stale UI cache.
enum HomeReadIndex {
    static func migrate(_ db: Database) throws {
        // Migrations run in GRDB's transaction before this pool is
        // published. Permit only this index-column backfill if a reset was
        // interrupted on an older version; restore its guard before commit.
        // A failed migration rolls the DDL back along with the backfill.
        let resetGuard = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE type='trigger' AND name='reset_guard_activity_UPDATE'")
        if resetGuard != nil { try db.execute(sql: "DROP TRIGGER reset_guard_activity_UPDATE") }
        try db.execute(sql: """
            ALTER TABLE assets ADD COLUMN historyMetadataSafe INTEGER NOT NULL DEFAULT 1;
            UPDATE assets SET historyMetadataSafe=NOT oath_phishing_metadata(name,symbol);
            CREATE TRIGGER asset_history_metadata_insert AFTER INSERT ON assets BEGIN
                UPDATE assets SET historyMetadataSafe=NOT oath_phishing_metadata(NEW.name,NEW.symbol) WHERE id=NEW.id;
            END;
            CREATE TRIGGER asset_history_metadata_update AFTER UPDATE OF name,symbol ON assets
            WHEN OLD.name IS NOT NEW.name OR OLD.symbol IS NOT NEW.symbol BEGIN
                UPDATE assets SET historyMetadataSafe=NOT oath_phishing_metadata(NEW.name,NEW.symbol) WHERE id=NEW.id;
            END;

            ALTER TABLE activity ADD COLUMN sortTimestamp DOUBLE NOT NULL DEFAULT 0;
            UPDATE activity SET sortTimestamp=COALESCE((SELECT outcomeAt FROM transactionEvidence
                WHERE accountID=activity.accountID AND transactionID=activity.transactionID),timestamp);
            CREATE INDEX activity_wallet_sort ON activity(walletID,sortTimestamp DESC,id DESC);
            CREATE INDEX activity_wallet_asset_sort ON activity(walletID,assetID,sortTimestamp DESC,id DESC);
            CREATE INDEX activity_account_asset_sort ON activity(accountID,assetID,sortTimestamp DESC,id DESC);
            CREATE INDEX activity_wallet_network_sort ON activity(walletID,networkID,sortTimestamp DESC,id DESC);
            CREATE INDEX activity_account_transaction ON activity(accountID,transactionID);

            CREATE TRIGGER activity_sort_insert AFTER INSERT ON activity BEGIN
                UPDATE activity SET sortTimestamp=COALESCE((SELECT outcomeAt FROM transactionEvidence
                    WHERE accountID=NEW.accountID AND transactionID=NEW.transactionID),NEW.timestamp) WHERE id=NEW.id;
            END;
            CREATE TRIGGER activity_sort_update AFTER UPDATE OF timestamp,accountID,transactionID ON activity
            WHEN OLD.timestamp IS NOT NEW.timestamp OR OLD.accountID IS NOT NEW.accountID
                OR OLD.transactionID IS NOT NEW.transactionID BEGIN
                UPDATE activity SET sortTimestamp=COALESCE((SELECT outcomeAt FROM transactionEvidence
                    WHERE accountID=NEW.accountID AND transactionID=NEW.transactionID),NEW.timestamp) WHERE id=NEW.id;
            END;
            CREATE TRIGGER evidence_sort_insert AFTER INSERT ON transactionEvidence BEGIN
                UPDATE activity SET sortTimestamp=COALESCE(NEW.outcomeAt,timestamp)
                    WHERE accountID=NEW.accountID AND transactionID=NEW.transactionID;
            END;
            CREATE TRIGGER evidence_sort_delete AFTER DELETE ON transactionEvidence BEGIN
                UPDATE activity SET sortTimestamp=timestamp
                    WHERE accountID=OLD.accountID AND transactionID=OLD.transactionID;
            END;
            CREATE TRIGGER evidence_sort_update AFTER UPDATE OF outcomeAt,accountID,transactionID ON transactionEvidence
            WHEN OLD.outcomeAt IS NOT NEW.outcomeAt OR OLD.accountID IS NOT NEW.accountID
                OR OLD.transactionID IS NOT NEW.transactionID BEGIN
                UPDATE activity SET sortTimestamp=COALESCE((SELECT outcomeAt FROM transactionEvidence
                    WHERE accountID=activity.accountID AND transactionID=activity.transactionID),timestamp)
                    WHERE (accountID=OLD.accountID AND transactionID=OLD.transactionID)
                       OR (accountID=NEW.accountID AND transactionID=NEW.transactionID);
            END;
            DROP VIEW visibleActivity;
            """)
        try HistorySafety.createVisibilityView(db, indexedMetadata: true)
        try indexUncoveredRelationships(db)
        if let resetGuard { try db.execute(sql: resetGuard) }
    }

    /// Audit every child relationship, not only the EVM tables. Metadata
    /// upserts and wallet cleanup otherwise scan entire chain ledgers for FK
    /// checks. Reuse an existing leading key when it already narrows the lookup;
    /// do not add redundant indexes for every possible column combination.
    private static func indexUncoveredRelationships(_ db: Database) throws {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
        for table in tables {
            let complete = Set(try Row.fetchAll(db, sql: "PRAGMA index_list(\(table.quotedDatabaseIdentifier))")
                .filter { (row: Row) in !(row["partial"] as Bool) }.map { (row: Row) -> String in row["name"] })
            var leading = Set(try db.indexes(on: table).filter { complete.contains($0.name) }.compactMap { $0.columns.first })
            if let primary = try db.primaryKey(table).columns.first { leading.insert(primary) }
            for foreignKey in try db.foreignKeys(on: table) {
                let columns = foreignKey.originColumns
                guard !columns.contains(where: leading.contains) else { continue }
                let name = "relationship_" + table + "_" + columns.joined(separator: "_")
                try db.execute(sql: "CREATE INDEX \(name.quotedDatabaseIdentifier) ON \(table.quotedDatabaseIdentifier)(\(columns.map(\.quotedDatabaseIdentifier).joined(separator: ",")))")
                if let first = columns.first { leading.insert(first) }
            }
        }
    }
}
