import Foundation
import GRDB
import OathAnkr

public struct TronSubmissionState: Sendable {
    public let state: String
    public let accepted: Bool
}

extension OathDatabase {
    /// Submission UI uses acknowledged submission and final journal outcomes,
    /// never an attempted broadcast or a tentative explorer/history result.
    public func tronSubmission(walletID:String,hash:String) async throws -> TronSubmissionState? {
        guard TronIdentity.hash(hash) else { throw TronSendError.changed }
        return try await pool.read { db in
            guard let row = try Row.fetchOne(db,sql:"""
                SELECT s.state, p.submittedAt FROM sends s JOIN tronSendPlans p ON p.sendID=s.id
                WHERE s.walletID=? AND s.networkID='tron' AND s.transactionID=? AND s.signedPayload IS NOT NULL LIMIT 1
                """,arguments:[walletID,"tron:"+hash]) else { return nil }
            let state: String = row["state"], acknowledged: Double? = row["submittedAt"]
            return .init(state:state,accepted:state == "confirmed" || (["signed","broadcast"].contains(state) && acknowledged != nil))
        }
    }

    public func tronSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID == "tron", let id = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db,key:id) else { return false }
            return try Bool.fetchOne(db,sql:"""
                SELECT EXISTS(SELECT 1 FROM tronTransactions t JOIN tronSync s ON s.accountID=t.accountID JOIN transactions tx ON tx.id=?
                WHERE t.accountID=? AND t.hash=? AND s.observedAt>=tx.timestamp AND s.failure IS NULL)
                """,arguments:[tx.id,send.accountID,tx.hash]) == true
        }
    }
    /// Reserve the sender, including duplicate imports in other wallets. Concurrent sends must not spend the same balance or resources.
    public func queueTronSend(sendID: String, plan: TronSendPlan) async throws {
        try plan.validate()
        guard plan.network == .mainnet else { throw TronSendError.wrongNetwork }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "draft", send.networkID == "tron",
                  let account = try AccountRecord.fetchOne(db,key:send.accountID), account.walletID == send.walletID,
                  account.networkID == "tron", try TronIdentity.address(account.address) == plan.sender,
                  let asset = try AssetRecord.fetchOne(db,key:send.assetID), asset.networkID == "tron", asset.reference == plan.reference, asset.decimals == plan.decimals,
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.amount) else { throw TronSendError.changed }
            let others = try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='tron' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{ try TronIdentity.address($0.senderAddress) == plan.sender }) else { throw TronSendError.busy }
            try db.execute(sql:"INSERT INTO tronSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
        }
    }
    public func tronSendPlan(sendID: String) async throws -> TronSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db,sql:"SELECT plan FROM tronSendPlans WHERE sendID=?",arguments:[sendID])
                .map { try JSONDecoder().decode(TronSendPlan.self,from:$0) }
        }
    }
    public func journalTronSignature(sendID: String, signed: TronSignedSend) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "queued", send.networkID == "tron",
                  let bytes = try Data.fetchOne(db,sql:"SELECT plan FROM tronSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(TronSendPlan.self,from:bytes)
            try plan.validate()
            guard plan.network == .mainnet, send.amountAtomic == String(plan.amount),
                  send.recipient == plan.recipient, try TronIdentity.address(send.senderAddress) == plan.sender else { throw TronSendError.changed }
            try TronSendCrypto.verify(signed,plan:plan)
            let now = Date.now.timeIntervalSince1970, id = "tron:"+signed.hash
            try TransactionRecord(id:id,networkID:"tron",hash:signed.hash,state:"pending",timestamp:now,
                                  feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            if plan.removal == nil {
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,
                networkID:"tron",transactionID:id,assetID:send.assetID,direction:plan.sender == plan.recipient ? "self":"outgoing",
                amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            }
            if let removal=plan.removal { try Self.journalPermissionRemoval(.tron(removal),send:send,db:db) }
            send.signedPayload = try JSONEncoder().encode(signed); send.transactionID = id; send.state = "signed"; send.updatedAt = now
            try send.update(db)
        }
    }
    /// Acceptance is durable but keeps the send pending and its sender reserved.
    /// Only validated execution or proven ledger-range expiry settles a send.
    /// A timeout or local quote expiration never releases a signed transaction.
    public func settleTronSend(sendID: String, receipt: TronSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.networkID == "tron",
                  ["signed","broadcast","confirmed","failed"].contains(send.state),
                  send.transactionID == "tron:"+receipt.hash, let raw = send.signedPayload else { throw StoreError.invalidTransition }
            let signed = try JSONDecoder().decode(TronSignedSend.self,from:raw)
            guard signed.hash == receipt.hash else { throw TronSendError.changed }
            guard let planBytes = try Data.fetchOne(db,sql:"SELECT plan FROM tronSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.missingRecord }
            let plan = try JSONDecoder().decode(TronSendPlan.self,from:planBytes)
            try TronSendCrypto.verify(signed,plan:plan)
            if receipt.outcome == .submitted {
                guard receipt.fee == nil, receipt.block == nil else { throw TronSendError.changed }
                // A late acknowledgement cannot overwrite a terminal outcome.
                if ["signed","broadcast"].contains(send.state) {
                    try db.execute(sql:"UPDATE tronSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",
                                   arguments:[Date.now.timeIntervalSince1970,sendID])
                }
                return
            }
            if receipt.outcome == .expired {
                guard receipt.fee == nil, receipt.block == nil else { throw TronSendError.changed }
            } else {
                guard let fee = receipt.fee, fee <= UInt64(Int64.max), let block = receipt.block, block >= plan.blockNumber else { throw TronSendError.changed }
            }
            let state = receipt.outcome == .confirmed ? "confirmed":"failed"
            guard !["confirmed","failed"].contains(send.state) || send.state == state else { throw StoreError.invalidTransition }
            let failureCode = state == "failed" ? (receipt.outcome == .expired ? "expired":"executionFailed"):nil
            guard send.state != "failed" || send.failureCode == failureCode else { throw StoreError.invalidTransition }
            guard var tx = try TransactionRecord.fetchOne(db,key:"tron:"+receipt.hash) else { throw StoreError.missingRecord }
            tx.state = state; tx.feeAtomic = receipt.fee.map(String.init); tx.updatedAt = Date.now.timeIntervalSince1970
            tx.blockHeight = receipt.block.flatMap(Int64.init(exactly:))
            try tx.update(db)
            send.state = state; send.failureCode = failureCode; send.updatedAt = tx.updatedAt
            try send.update(db)
            if receipt.outcome != .expired { try db.execute(sql:"INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)",arguments:[sendID]) }
            else { try db.execute(sql:"UPDATE sendBalanceRefreshes SET completedAt=? WHERE sendID=?",arguments:[tx.updatedAt,sendID]) }
        }
    }
}
