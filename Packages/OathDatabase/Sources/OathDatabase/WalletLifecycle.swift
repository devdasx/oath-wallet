import Foundation
import GRDB

/// Public projection of deletion intent authenticated inside the encrypted vault.
public struct WalletLifecycle: Sendable {
    public let id: String
    public let deletedAt: Double?
    public init(id: String, deletedAt: Double?) { self.id = id; self.deletedAt = deletedAt }
}

extension OathDatabase {
    public func reorderWallets(_ ids: [String]) async throws {
        guard Set(ids).count == ids.count else { throw StoreError.invalidValue("wallet order") }
        try await pool.write { db in
            let active = try String.fetchAll(db, sql: "SELECT id FROM wallets WHERE deletedAt IS NULL")
            guard Set(active) == Set(ids) else { throw StoreError.staleSync }
            for (index, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE wallets SET sortOrder=? WHERE id=?", arguments: [index, id])
            }
        }
    }

    public func validateWalletRemoval(_ ids: Set<String>) async throws {
        try await pool.read { db in
            for id in ids {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM sends WHERE walletID=? AND state IN ('queued','signed','broadcast') LIMIT 1", arguments: [id]) == nil else {
                    throw StoreError.invalidTransition
                }
            }
        }
    }

    public func reconcileWalletLifecycle(_ states: [WalletLifecycle]) async throws {
        guard states.allSatisfy({ $0.deletedAt?.isFinite != false }) else { throw StoreError.invalidValue("wallet deletion date") }
        try await pool.write { db in
            for state in states {
                guard let wallet = try WalletRecord.fetchOne(db, key: state.id) else { throw StoreError.missingRecord }
                guard wallet.deletedAt != state.deletedAt else { continue }
                // Invalidate every outstanding network ticket on remove/restore.
                try db.execute(sql: "UPDATE accounts SET syncGeneration=syncGeneration+1 WHERE walletID=?", arguments: [state.id])
                // Electrum scans have their own run identity, independent of
                // the shared account generation used by indexed chains.
                try db.execute(sql: "UPDATE bitcoinWallets SET scanID=NULL WHERE accountID IN (SELECT id FROM accounts WHERE walletID=?)", arguments: [state.id])
                try db.execute(sql: "UPDATE wallets SET deletedAt=? WHERE id=?", arguments: [state.deletedAt, state.id])
                if state.deletedAt != nil {
                    try db.execute(sql: "UPDATE cloudBackups SET enabled=0,encryptedDocument=NULL WHERE walletID=?", arguments: [state.id])
                    try db.execute(sql: "DELETE FROM settings WHERE key='activeWalletID' AND value=?", arguments: [state.id])
                }
            }
        }
    }
}
