import Foundation
import GRDB

extension OathDatabase {
    static func migrateWalletRemovalReservations(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE walletRemovalReservations (
                walletID TEXT PRIMARY KEY NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                token TEXT NOT NULL
            );
            """)
        let tables = ["sends", "walletConnectBitcoinSubmissions", "walletConnectSolanaSubmissions",
                      "walletConnectSuiSubmissions", "walletConnectTonSubmissions",
                      "walletConnectNearSubmissions", "walletConnectStellarSubmissions",
                      "walletConnectXrplSubmissions"]
        for table in tables {
            let states = table == "sends" ? "'queued','signed','broadcast'"
                : table == "walletConnectSuiSubmissions" ? "'signed','unknown'" : "'signed','unknown','accepted'"
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER removal_guard_\(table)_\(operation) BEFORE \(operation) ON \(table)
                    WHEN NEW.state IN (\(states)) AND EXISTS(
                        SELECT 1 FROM walletRemovalReservations WHERE walletID=NEW.walletID)
                    BEGIN SELECT RAISE(ABORT, 'Wallet removal in progress'); END;
                    """)
            }
        }
    }

    /// Validation and reservation share one writer transaction. A concurrent
    /// journal write must either win first and block removal, or be rejected.
    public func reserveWalletRemoval(_ ids: Set<String>) async throws -> String {
        guard !ids.isEmpty else { throw StoreError.invalidValue("wallet removal") }
        return try await pool.write { db in
            try Self.requireWalletSyncAllowed(db)
            let token = UUID().uuidString
            for id in ids.sorted() {
                guard try WalletRecord.fetchOne(db, key: id) != nil else { throw StoreError.missingRecord }
                guard try String.fetchOne(db, sql: "SELECT token FROM walletRemovalReservations WHERE walletID=?", arguments: [id]) == nil else {
                    throw StoreError.invalidTransition
                }
                try Self.requireNoPendingWalletTransactions(id, db: db)
                try db.execute(sql: "INSERT INTO walletRemovalReservations(walletID,token) VALUES(?,?)", arguments: [id, token])
            }
            return token
        }
    }

    public func pendingWalletRemovalReservations() async throws -> Set<String> {
        try await pool.read { Set(try String.fetchAll($0, sql: "SELECT DISTINCT token FROM walletRemovalReservations")) }
    }

    /// Release only a captured operation, never a newer reservation. Startup
    /// calls this after reconciling the authenticated vault's persisted state.
    public func finishWalletRemovalReservations(_ tokens: Set<String>) async throws {
        try await pool.write { db in
            for token in tokens {
                try db.execute(sql: "DELETE FROM walletRemovalReservations WHERE token=?", arguments: [token])
            }
        }
    }
}
