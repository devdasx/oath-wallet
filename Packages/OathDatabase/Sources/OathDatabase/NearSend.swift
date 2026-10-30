import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    /// Submission UI observes the finality-checked send journal, not a tentative
    /// explorer/history row which can include unconfirmed execution results.
    public func nearSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard SolanaIdentity.isAddress(hash) else { throw NearSendError.changed }
        return try await pool.read { db in
            try SendRecord.fetchOne(db,sql:"SELECT * FROM sends WHERE walletID=? AND networkID='near' AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,"near:"+hash])
        }
    }

    public func nearSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID == "near", let id = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db,key:id) else { return false }
            return try Bool.fetchOne(db,sql:"""
                SELECT EXISTS(SELECT 1 FROM nearTransactions t JOIN nearSync s ON s.accountID=t.accountID JOIN transactions tx ON tx.id=?
                WHERE t.accountID=? AND t.hash=? AND s.observedAt>=tx.timestamp AND s.failure IS NULL)
                """,arguments:[tx.id,send.accountID,tx.hash]) == true
        }
    }
    /// Reserve the sender, including duplicate imports in other wallets. Concurrent sends must not spend the same balance or resources.
    public func queueNearSend(sendID: String, plan: NearSendPlan) async throws {
        try plan.validate()
        guard plan.network == .mainnet else { throw NearSendError.wrongNetwork }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "draft", send.networkID == "near",
                  let account = try AccountRecord.fetchOne(db,key:send.accountID), account.walletID == send.walletID,
                  account.networkID == "near", try NearIdentity.address(account.address) == plan.sender,
                  let asset = try AssetRecord.fetchOne(db,key:send.assetID), asset.networkID == "near", asset.reference == plan.reference, asset.decimals == plan.decimals,
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.amount) else { throw NearSendError.changed }
            guard try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM walletConnectNearSubmissions WHERE owner=? AND chain='near:mainnet' AND state IN ('signed','unknown','accepted')",arguments:[plan.sender]) == 0 else { throw NearSendError.busy }
            let others = try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='near' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{ try NearIdentity.address($0.senderAddress) == plan.sender }) else { throw NearSendError.busy }
            try db.execute(sql:"INSERT INTO nearSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
        }
    }
    public func nearSendPlan(sendID: String) async throws -> NearSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db,sql:"SELECT plan FROM nearSendPlans WHERE sendID=?",arguments:[sendID])
                .map { try JSONDecoder().decode(NearSendPlan.self,from:$0) }
        }
    }
    public func journalNearSignature(sendID: String, signed: NearSignedSend) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "queued", send.networkID == "near",
                  let bytes = try Data.fetchOne(db,sql:"SELECT plan FROM nearSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(NearSendPlan.self,from:bytes)
            try plan.validate()
            guard plan.network == .mainnet, send.amountAtomic == String(plan.amount),
                  send.recipient == plan.recipient, try NearIdentity.address(send.senderAddress) == plan.sender else { throw NearSendError.changed }
            try NearSendCrypto.verify(signed,plan:plan)
            let now = Date.now.timeIntervalSince1970, id = "near:"+signed.hash
            try TransactionRecord(id:id,networkID:"near",hash:signed.hash,state:"pending",timestamp:now,
                                  feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,
                networkID:"near",transactionID:id,assetID:send.assetID,direction:plan.sender == plan.recipient ? "self":"outgoing",
                amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            send.signedPayload = try JSONEncoder().encode(signed); send.transactionID = id; send.state = "signed"; send.updatedAt = now
            try send.update(db)
        }
    }
    /// Only validated execution or proven ledger-range expiry settles a send.
    /// A timeout or local quote expiration never releases a signed transaction.
    public func settleNearSend(sendID: String, receipt: NearSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.networkID == "near",
                  ["signed","broadcast","confirmed","failed"].contains(send.state),
                  send.transactionID == "near:"+receipt.hash, let raw = send.signedPayload else { throw StoreError.invalidTransition }
            let signed = try JSONDecoder().decode(NearSignedSend.self,from:raw)
            guard signed.hash == receipt.hash else { throw NearSendError.changed }
            guard let planBytes = try Data.fetchOne(db,sql:"SELECT plan FROM nearSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.missingRecord }
            let plan = try JSONDecoder().decode(NearSendPlan.self,from:planBytes)
            try NearSendCrypto.verify(signed,plan:plan)
            if receipt.outcome == .accepted {
                guard receipt.fee == nil, receipt.block == nil else { throw NearSendError.changed }
                // Idempotent late acknowledgements cannot regress a terminal send.
                try db.execute(sql:"UPDATE nearSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",
                               arguments:[Date.now.timeIntervalSince1970,sendID])
                return
            }
            if receipt.outcome == .expired {
                guard receipt.fee == nil, receipt.block == nil else { throw NearSendError.changed }
            } else {
                guard let fee = receipt.fee, (try? NearSendAmount.checked(fee)) == fee, let block = receipt.block, block >= plan.blockHeight else { throw NearSendError.changed }
            }
            let state = receipt.outcome == .confirmed ? "confirmed":"failed"
            guard !["confirmed","failed"].contains(send.state) || send.state == state else { throw StoreError.invalidTransition }
            let failureCode = state == "failed" ? (receipt.outcome == .expired ? "expired":"executionFailed"):nil
            guard send.state != "failed" || send.failureCode == failureCode else { throw StoreError.invalidTransition }
            guard var tx = try TransactionRecord.fetchOne(db,key:"near:"+receipt.hash) else { throw StoreError.missingRecord }
            tx.state = state; tx.feeAtomic = receipt.fee; tx.updatedAt = Date.now.timeIntervalSince1970
            tx.blockHeight = receipt.block.flatMap(Int64.init(exactly:))
            try tx.update(db)
            send.state = state; send.failureCode = failureCode; send.updatedAt = tx.updatedAt
            try send.update(db)
            if receipt.outcome != .expired { try db.execute(sql:"INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)",arguments:[sendID]) }
            else { try db.execute(sql:"UPDATE sendBalanceRefreshes SET completedAt=? WHERE sendID=?",arguments:[tx.updatedAt,sendID]) }
        }
    }
}
