import Foundation
import GRDB
import OathAnkr

/// Broadcast acknowledgement is distinct from both a local attempt and finality.
public struct SendSubmissionState: Equatable, Sendable {
    public let state: String
    public let accepted: Bool
    public let failureCode: String?
    public let replacementHash: String?
    public let awaitingConfirmation: Bool
    public enum Outcome: String, Sendable {
        case checking, submitted, confirmed, failed, cancelled, replaced, expired, awaitingConfirmation
    }
    public var outcome: Outcome {
        if state == "confirmed" { return .confirmed }
        if state == "cancelled" { return .cancelled }
        if state == "failed" {
            switch failureCode {
            case "canceled", "cancelled": return .cancelled
            case "replaced": return .replaced
            case "expired": return .expired
            default: return .failed
            }
        }
        if awaitingConfirmation { return .awaitingConfirmation }
        return accepted ? .submitted : .checking
    }
    /// A foreground provider acknowledgement can outlive a failed local save.
    /// It overrides only an unknown submission, never a newer terminal or reorg state.
    public func presentationOutcome(broadcastAcknowledged: Bool) -> Outcome {
        outcome == .checking && broadcastAcknowledged ? .submitted : outcome
    }
    public init(state: String, accepted: Bool, failureCode: String? = nil, replacementHash: String? = nil, awaitingConfirmation: Bool = false) {
        self.state = state; self.accepted = accepted; self.failureCode = failureCode
        self.replacementHash = replacementHash; self.awaitingConfirmation = awaitingConfirmation
    }
}

extension OathDatabase {
    /// Observe positive provider acknowledgement without loading signed payloads.
    /// A local hash or `broadcast` state alone is never evidence of acceptance.
    public func observeSendSubmission(walletID: String, networkID: String, hash: String) -> AsyncThrowingStream<SendSubmissionState?, Error> {
        stream { db in try Self.submission(db, walletID: walletID, networkID: networkID, hash: hash) }
    }

    public func sendSubmission(walletID: String, networkID: String, hash: String) async throws -> SendSubmissionState? {
        try await pool.read { db in try Self.submission(db, walletID: walletID, networkID: networkID, hash: hash) }
    }

    private static func submission(_ db: Database, walletID: String, networkID: String, hash: String) throws -> SendSubmissionState? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.id,s.state,s.failureCode,t.state AS receiptState,t.blockHeight,t.blockHash,e.replacementHash
            FROM sends s JOIN wallets w ON w.id=s.walletID
            LEFT JOIN transactions t ON t.id=s.transactionID AND t.networkID=s.networkID
            LEFT JOIN transactionEvidence e ON e.transactionID=s.transactionID AND e.accountID=s.accountID
            WHERE s.walletID=? AND s.networkID=? AND s.transactionID=? AND s.signedPayload IS NOT NULL
                AND w.deletedAt IS NULL AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
            LIMIT 1
            """, arguments: [walletID, networkID, networkID + ":" + hash]) else { return nil }
        let id: String = row["id"], journalState: String = row["state"]
        let failure: String? = row["failureCode"], replacement: String? = row["replacementHash"]
        let receiptState: String? = row["receiptState"]
        let height: Int64? = row["blockHeight"], blockHash: String? = row["blockHash"]
        // EVM block confirmation and finality are different milestones. Keep
        // reservations/tracking in the journal while showing verified execution.
        let included = ["signed", "broadcast"].contains(journalState)
            && EVMSendNetwork(rawValue: networkID) != nil
            && height.map({ $0 >= 0 }) == true
            && blockHash.map(AnkrQuantity.hash) == true
            && ["confirmed", "failed"].contains(receiptState ?? "")
        let state = included ? receiptState! : journalState
        func snapshot(_ accepted: Bool) -> SendSubmissionState {
            .init(state: state, accepted: accepted, failureCode: failure, replacementHash: replacement,
                  awaitingConfirmation: receiptState == "reorged")
        }
        if state == "confirmed" { return snapshot(true) }
        guard ["signed", "broadcast"].contains(state) else { return snapshot(false) }
        // All identifiers are compile-time constants, never user input. Include
        // both Arc's legacy journal and the shared EVM journal during upgrades.
        for table in ["bitcoinSendPlans", "evmSendPlans", "arcSendPlans", "aptosSendPlans", "tonSendPlans", "solanaSendPlans", "tronSendPlans", "nearSendPlans", "polkadotSendPlans", "thorchainSendPlans", "xrplSendPlans", "stellarSendPlans"] {
            if try Double.fetchOne(db, sql: "SELECT submittedAt FROM \(table) WHERE sendID=?", arguments: [id]) != nil {
                return snapshot(true)
            }
        }
        return snapshot(false)
    }

    /// Call only after the broadcaster validates acknowledgement of these exact bytes.
    public func acknowledgeBitcoinSend(_ id: String, hash: String) async throws {
        try await pool.write { db in
            guard let send = try SendRecord.fetchOne(db, key: id),
                  ["bitcoin", "bitcoincash", "litecoin", "dogecoin"].contains(send.networkID),
                  send.signedPayload != nil, send.transactionID == send.networkID + ":" + hash,
                  ["signed", "broadcast", "confirmed"].contains(send.state) else { throw StoreError.invalidTransition }
            try db.execute(sql: "UPDATE bitcoinSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?", arguments: [Date.now.timeIntervalSince1970, id])
        }
    }
}
