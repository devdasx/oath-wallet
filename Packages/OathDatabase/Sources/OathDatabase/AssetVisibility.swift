import Foundation
import GRDB

extension OathDatabase {
    static func migrateAssetVisibility(_ db: Database) throws {
        // Keep v66's historical schema for migration ordering, but never fan out
        // existing selections when an older installation skips straight to v67.
        // v67 removes this retired shared table and account-insert trigger.
        try db.execute(sql: """
            CREATE TABLE hiddenAssets (
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                assetID TEXT NOT NULL REFERENCES assets(id) ON DELETE CASCADE,
                PRIMARY KEY(walletID,assetID)
            );
            CREATE TABLE sharedTrackedAssets (
                assetID TEXT PRIMARY KEY NOT NULL,
                networkID TEXT NOT NULL, addedAt DOUBLE NOT NULL,
                FOREIGN KEY(assetID,networkID) REFERENCES assets(id,networkID) ON DELETE CASCADE
            );
            CREATE TRIGGER track_shared_assets_on_account_insert AFTER INSERT ON accounts
            BEGIN
                INSERT OR IGNORE INTO trackedAssets(accountID,assetID,networkID,addedAt)
                    SELECT NEW.id,assetID,networkID,addedAt FROM sharedTrackedAssets WHERE networkID=NEW.networkID;
            END;
            """)
        for table in ["hiddenAssets", "sharedTrackedAssets"] {
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                    WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                    BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                    """)
            }
        }
    }

    public func setAssetHidden(_ hidden: Bool, assetID: String, walletID: String) async throws {
        try await pool.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')") == false,
                  try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM wallets w JOIN walletAccounts c ON c.walletID=w.id
                        JOIN assets a ON a.networkID=c.networkID
                        WHERE w.id=? AND w.deletedAt IS NULL AND a.id=?)
                    """, arguments: [walletID, assetID]) == true else { throw StoreError.missingRecord }
            if hidden {
                try db.execute(sql: "INSERT INTO hiddenAssets(walletID,assetID) VALUES(?,?) ON CONFLICT DO NOTHING",
                               arguments: [walletID, assetID])
            } else {
                // Pin restored discovered tokens so they stay on Home even if a
                // later inventory drops a zero balance. This is not a global add.
                try db.execute(sql: """
                    INSERT OR IGNORE INTO trackedAssets(accountID,assetID,networkID,addedAt)
                        SELECT c.id,a.id,a.networkID,? FROM walletAccounts c JOIN assets a ON a.networkID=c.networkID
                        WHERE c.walletID=? AND a.id=? AND a.reference<>'native'
                        AND EXISTS(SELECT 1 FROM hiddenAssets WHERE walletID=? AND assetID=?)
                    """, arguments: [Date().timeIntervalSince1970, walletID, assetID, walletID, assetID])
                try db.execute(sql: "DELETE FROM hiddenAssets WHERE walletID=? AND assetID=?", arguments: [walletID, assetID])
            }
        }
    }

    /// Independent of balance discovery and portfolio filters, so every hidden
    /// asset remains available to restore even when its current balance is zero.
    public func observeHiddenAssets(walletID: String) -> AsyncThrowingStream<[AssetRecord], Error> {
        stream { db in
            try AssetRecord.fetchAll(db, sql: """
                SELECT a.* FROM hiddenAssets h JOIN assets a ON a.id=h.assetID
                JOIN wallets w ON w.id=h.walletID
                WHERE h.walletID=? AND w.deletedAt IS NULL ORDER BY a.name COLLATE NOCASE,a.networkID,a.id
                """, arguments: [walletID])
        }
    }
}
