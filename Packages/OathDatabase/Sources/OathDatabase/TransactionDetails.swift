import Foundation
import GRDB

/// A wallet-scoped projection: a token fee always uses the chain's native asset.
public struct TransactionDetails: Equatable, Sendable {
    public let transaction: TransactionRecord
    /// Account-scoped cancellation/replacement evidence takes precedence over
    /// the original transaction's raw pending state, just as in history rows.
    public let state: String
    public let transfers: [TransferRecord]
    public let feeAsset: AssetRecord?
    public let replacementHash: String?
    /// Current cached value in the requested display currency. Missing market
    /// data stays unknown; a missing price must never turn a paid fee into zero.
    public let feeFiatValue: Decimal?
}

extension OathDatabase {
    public func transactionDetails(accountID: String, transactionID: String, currency: String = "USD") async throws -> TransactionDetails? {
        try await pool.read { db in
            try Self.transactionDetails(db, accountID: accountID, transactionID: transactionID, currency: currency)
        }
    }

    public func observeTransactionDetails(accountID: String, transactionID: String, currency: String) -> AsyncThrowingStream<TransactionDetails?, Error> {
        stream { db in
            try Self.transactionDetails(db, accountID: accountID, transactionID: transactionID, currency: currency)
        }
    }

    private static func transactionDetails(_ db: Database, accountID: String, transactionID: String, currency: String) throws -> TransactionDetails? {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM visibleActivity WHERE accountID=? AND transactionID=?)", arguments: [accountID, transactionID]) == true,
              let tx = try TransactionRecord.fetchOne(db, key: transactionID) else { return nil }
        let asset = try AssetRecord.fetchOne(db, sql: "SELECT * FROM assets WHERE networkID=? AND reference='native'", arguments: [tx.networkID])
        let price: String? = try asset.flatMap {
            try String.fetchOne(db, sql: "SELECT value FROM prices WHERE assetID=? AND currency='USD' ORDER BY observedAt DESC LIMIT 1", arguments: [$0.id])
        }
        let exchangeRate = try Self.exchangeRates(db)?.rate(for: currency) ?? (currency == "USD" ? 1 : nil)
        var fiat: Decimal?
        if let fee = tx.feeAtomic, let asset,
           let units = try? AtomicAmount(fee).units(decimals: asset.decimals),
           let quantity = Decimal(string: units, locale: Locale(identifier: "en_US_POSIX")) {
            if quantity == 0 { fiat = 0 }
            else if let price, let usd = Decimal(string: price, locale: Locale(identifier: "en_US_POSIX")),
                    let exchangeRate, let localPrice = FiatConversion.multiply(usd, exchangeRate) {
                fiat = FiatConversion.multiply(quantity, localPrice)
            }
        }
        let outcome = try String.fetchOne(db, sql: "SELECT outcome FROM transactionEvidence WHERE accountID=? AND transactionID=?",
                                         arguments: [accountID, transactionID])
        return TransactionDetails(transaction: tx, state: outcome ?? tx.state,
            transfers: try TransferRecord.fetchAll(db, sql: """
                SELECT tr.* FROM transfers tr WHERE tr.transactionID=? AND EXISTS(
                    SELECT 1 FROM visibleActivity a WHERE a.transactionID=tr.transactionID
                        AND a.assetID=tr.assetID AND a.accountID=?) ORDER BY tr.eventIndex
                """, arguments: [transactionID, accountID]),
            feeAsset: asset,
            replacementHash: try String.fetchOne(db, sql: "SELECT replacementHash FROM transactionEvidence WHERE accountID=? AND transactionID=?", arguments: [accountID, transactionID]),
            feeFiatValue: fiat)
    }

    /// A conflict key is an actual spent outpoint, or an EVM sender + nonce.
    /// Only a mined competitor settles the outcome. Missing history alone is
    /// not evidence of cancellation; ordinary self-transfers are not cancels.
    static func saveTransactionEvidence(accountID: String, tx: TransactionRecord, keys: Set<String>, returnsToWallet: Bool, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet) VALUES(?,?,?,?)
            ON CONFLICT(accountID,transactionID) DO UPDATE SET conflictKeys=excluded.conflictKeys,returnsToWallet=excluded.returnsToWallet
            """, arguments: [accountID, tx.id, try JSONEncoder().encode(keys), returnsToWallet])
        try db.execute(sql: "DELETE FROM transactionConflictKeys WHERE accountID=? AND transactionID=?", arguments: [accountID, tx.id])
        for key in keys {
            try db.execute(sql: "INSERT INTO transactionConflictKeys(accountID,transactionID,conflictKey) VALUES(?,?,?)", arguments: [accountID, tx.id, key])
        }
        // Reconcile in both arrival orders (historical pages may arrive newest first).
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*,t.state,t.hash,t.timestamp FROM transactionEvidence e JOIN transactions t ON t.id=e.transactionID
            WHERE e.accountID=? AND t.networkID=? AND e.transactionID IN (
                SELECT other.transactionID FROM transactionConflictKeys mine
                JOIN transactionConflictKeys other ON other.accountID=mine.accountID AND other.conflictKey=mine.conflictKey
                WHERE mine.accountID=? AND mine.transactionID=?)
            """, arguments: [accountID, tx.networkID, accountID, tx.id])
        let decoder = JSONDecoder()
        for old in rows {
            let oldID: String = old["transactionID"], oldState: String = old["state"]
            guard oldState != "confirmed", oldState != "failed" else { continue }
            try db.execute(sql: "UPDATE transactionEvidence SET outcome=NULL,replacementHash=NULL,outcomeAt=NULL WHERE accountID=? AND transactionID=?", arguments: [accountID, oldID])
            let oldKeys = try decoder.decode(Set<String>.self, from: old["conflictKeys"])
            guard !oldKeys.isEmpty else { continue }
            for winner in rows where (winner["state"] as String) == "confirmed" || (winner["state"] as String) == "failed" {
                let winnerID: String = winner["transactionID"]
                guard winnerID != oldID else { continue }
                let winnerKeys = try decoder.decode(Set<String>.self, from: winner["conflictKeys"])
                guard !oldKeys.isDisjoint(with: winnerKeys) else { continue }
                let canceled = (winner["returnsToWallet"] as Bool) && (winner["state"] as String) == "confirmed"
                try db.execute(sql: "UPDATE transactionEvidence SET outcome=?,replacementHash=?,outcomeAt=? WHERE accountID=? AND transactionID=?",
                    arguments: [canceled ? "canceled" : "replaced", winner["hash"] as String, winner["timestamp"] as Double, accountID, oldID])
                break
            }
        }
        if tx.state == "confirmed" || tx.state == "failed" {
            try db.execute(sql: "UPDATE transactionEvidence SET outcome=NULL,replacementHash=NULL,outcomeAt=NULL WHERE accountID=? AND transactionID=?", arguments: [accountID, tx.id])
        }
    }
}
