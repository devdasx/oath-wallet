import Foundation
import GRDB
import OathAnkr
import OathDiagnostics

extension TransactionRecord {
    /// Index pages can omit receipt fields. Missing metadata is not evidence
    /// that the receipt changed; a different block or outcome is.
    func retainingEVMReceipt(from old: TransactionRecord?) -> Self {
        guard let old, id == old.id, networkID == old.networkID,
              hash.lowercased() == old.hash.lowercased(),
              let height = blockHeight, height == old.blockHeight,
              state == old.state, ["confirmed", "failed"].contains(state) else { return self }
        var result = self
        if result.blockHash == nil { result.blockHash = old.blockHash }
        if result.feeAtomic == nil, result.blockHash?.lowercased() == old.blockHash?.lowercased() {
            result.feeAtomic = old.feeAtomic
        }
        return result
    }
}

extension OathDatabase {
    /// Repair receipt references erased by older sparse-page upserts, without
    /// network access. Stale generations, changed blocks and outcomes stay invalid.
    static func repairEVMHistoryReceiptReferences(_ db: Database) throws {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT c.evidence,c.blockHash AS receiptHash,t.id,t.hash,t.blockHeight,t.state
            FROM evmHistorySwaps c
            JOIN accounts a ON a.id=c.accountID AND a.syncGeneration=c.generation
            JOIN transactions t ON t.id=c.transactionID AND t.networkID=a.networkID
            WHERE t.blockHash IS NULL AND t.blockHeight IS NOT NULL
              AND t.state IN ('confirmed','failed') AND c.blockHash IS NOT NULL
            """)
        var repairs: [(String, String)] = []
        var reportedInvalidEvidence = false
        while let row = try rows.next() {
            let raw: Data = row["evidence"]
            // Oversized/absent optional evidence is not used to restore labels.
            guard raw.count <= 2_000_000 else { continue }
            do {
                let evidence = try JSONDecoder().decode(EVMHistoryEvidence.self, from: raw)
                let hash: String = row["hash"], block: String = row["receiptHash"], state: String = row["state"]
                let height: Int64 = row["blockHeight"]
                guard evidence.transaction["hash"].string?.lowercased() == hash.lowercased(),
                      evidence.receipt["transactionHash"].string?.lowercased() == hash.lowercased(),
                      evidence.receipt["blockHash"].string?.lowercased() == block.lowercased(),
                      let number = evidence.receipt["blockNumber"].string,
                      Int64(try AnkrQuantity.decimal(number)) == height,
                      let status = evidence.receipt["status"].string,
                      try AnkrQuantity.decimal(status) == (state == "confirmed" ? "1" : "0") else { continue }
                let id: String = row["id"]
                repairs.append((id, block))
            } catch {
                // Corrupt optional cache data must not block opening the wallet.
                // Report once per migration; no evidence or identities are logged.
                if !reportedInvalidEvidence {
                    OathDiagnostics.record(error, component: "database", operation: "repairHistoryReceiptReference", context: ["stage": "cached_evidence"])
                    reportedInvalidEvidence = true
                }
            }
        }
        // Finish reading before modifying the queried table. SQL failures propagate.
        for (id, block) in repairs {
            try db.execute(sql: "UPDATE transactions SET blockHash=? WHERE id=? AND blockHash IS NULL", arguments: [block,id])
        }
    }
}
