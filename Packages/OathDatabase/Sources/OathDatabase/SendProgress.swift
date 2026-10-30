import Foundation
import GRDB

/// Small, atomic presentation snapshot. Never reads signed payloads or keys.
public struct SendProgress: Equatable, Sendable {
    public enum Outcome: String, Sendable { case pending, confirmed, failed, cancelled, replaced }
    public let outcome: Outcome
    public let actualFee: String?
    public let blockHeight: Int64?
    public let replacementHash: String?
    public init(outcome: Outcome, actualFee: String? = nil, blockHeight: Int64? = nil, replacementHash: String? = nil) {
        self.outcome = outcome; self.actualFee = actualFee
        self.blockHeight = blockHeight; self.replacementHash = replacementHash
    }
}

extension OathDatabase {
    /// Observation is independent of the durable network worker. Closing a
    /// screen cancels only this subscription; reopening reads the latest state.
    public func observeSendProgress(sendID: String) -> AsyncThrowingStream<SendProgress?, Error> {
        stream { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT s.state,s.failureCode,t.state AS receiptState,t.feeAtomic,t.blockHeight,e.replacementHash
                FROM sends s JOIN wallets w ON w.id=s.walletID
                LEFT JOIN transactions t ON t.id=s.transactionID AND t.networkID=s.networkID
                LEFT JOIN transactionEvidence e ON e.transactionID=s.transactionID AND e.accountID=s.accountID
                WHERE s.id=? AND w.deletedAt IS NULL
                    AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                """, arguments: [sendID]) else { return nil }
            let state: String = row["state"], failure: String? = row["failureCode"]
            let outcome: SendProgress.Outcome
            switch state {
            case "confirmed": outcome = .confirmed
            case "cancelled": outcome = .cancelled
            case "failed":
                outcome = failure == "cancelled" ? .cancelled : failure == "replaced" ? .replaced : .failed
            default: outcome = .pending // Unknown, offline and reorged are never proof of failure.
            }
            let receiptState: String? = row["receiptState"], height: Int64? = row["blockHeight"]
            // The pending journal holds a fee cap, not a paid fee. A canceled
            // or replaced transaction did not incur the competitor's gas fee.
            let settled = (outcome == .confirmed || outcome == .failed) && receiptState == outcome.rawValue && height != nil
            return SendProgress(outcome: outcome, actualFee: settled ? row["feeAtomic"] : nil,
                blockHeight: settled ? height : nil,
                replacementHash: outcome == .cancelled || outcome == .replaced ? row["replacementHash"] : nil)
        }
    }
}
