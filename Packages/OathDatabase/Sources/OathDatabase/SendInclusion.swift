import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    /// Keep execution visible without settling the journal before finality.
    /// This runs only after validating the receipt against the signed plan.
    static func updateSendInclusion(_ db: Database, send: SendRecord, inclusion: EVMSendInclusion?,
                                    reference: String, minimumHeight: UInt64, maximumFee: UInt64?) throws {
        guard ["signed", "broadcast"].contains(send.state) else { return }
        guard let id = send.transactionID, var tx = try TransactionRecord.fetchOne(db, key: id) else {
            throw StoreError.missingRecord
        }
        if let inclusion {
            guard AnkrQuantity.hash(inclusion.blockHash), inclusion.height >= minimumHeight,
                  inclusion.height <= UInt64(Int64.max), inclusion.timestamp.isFinite, inclusion.timestamp > 0,
                  maximumFee.map({ inclusion.fee <= $0 }) ?? true else { throw EVMSendError.changed }
            if inclusion.succeeded, reference != "native" {
                guard let delivered = inclusion.deliveredAmount else { throw EVMSendError.changed }
                _ = try EVMSendAmount.checked(delivered)
            } else {
                guard inclusion.deliveredAmount == nil else { throw EVMSendError.changed }
            }
            let state = inclusion.succeeded ? "confirmed" : "failed"
            let changed = tx.state != state || tx.blockHash != inclusion.blockHash || tx.blockHeight != Int64(inclusion.height)
            tx.state = state; tx.blockHash = inclusion.blockHash; tx.blockHeight = Int64(inclusion.height)
            tx.feeAtomic = String(inclusion.fee); tx.timestamp = inclusion.timestamp
            tx.updatedAt = Date.now.timeIntervalSince1970
            try tx.update(db)
            if let delivered = inclusion.deliveredAmount {
                try db.execute(sql: "UPDATE activity SET amountAtomic=? WHERE id=?",
                    arguments: [delivered, send.accountID + ":" + tx.hash + ":" + reference])
            }
            if changed {
                try db.execute(sql: "INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",
                    arguments: [send.id])
            }
        } else if ["confirmed", "failed"].contains(tx.state) {
            // A formerly included receipt is no longer canonical/available.
            // Keep checking; absence is never proof of failure or replacement.
            tx.state = "reorged"; tx.blockHash = nil; tx.blockHeight = nil; tx.feeAtomic = nil
            tx.updatedAt = Date.now.timeIntervalSince1970
            try tx.update(db)
        }
    }
}
