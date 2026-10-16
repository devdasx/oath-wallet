import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func suiSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID == "sui", let id = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db,key:id) else { return false }
            return try Bool.fetchOne(db,sql:"""
                SELECT EXISTS(SELECT 1 FROM suiTransactions t JOIN suiSync s ON s.accountID=t.accountID
                WHERE t.accountID=? AND t.hash=? AND s.checkpoint>=t.checkpoint AND s.failure IS NULL)
                """,arguments:[send.accountID,tx.hash]) == true
        }
    }
    /// Reserve the sender, including duplicate imports in other wallets. Coin
    /// object versions and address balances must not fund overlapping sends.
    public func queueSuiSend(sendID: String, plan: SuiSendPlan) async throws {
        try plan.validate()
        guard plan.network == .mainnet else { throw SuiSendError.wrongNetwork }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "draft", send.networkID == "sui",
                  let account = try AccountRecord.fetchOne(db,key:send.accountID), account.walletID == send.walletID,
                  account.networkID == "sui", try SuiIdentity.address(account.address) == plan.sender,
                  let asset = try AssetRecord.fetchOne(db,key:send.assetID), asset.networkID == "sui", asset.reference == plan.reference,
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.amount) else { throw SuiSendError.changed }
            let others = try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='sui' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{ try SuiIdentity.address($0.senderAddress) == plan.sender }) else { throw SuiSendError.busy }
            try db.execute(sql:"INSERT INTO suiSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
        }
    }
    public func suiSendPlan(sendID: String) async throws -> SuiSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db,sql:"SELECT plan FROM suiSendPlans WHERE sendID=?",arguments:[sendID])
                .map { try JSONDecoder().decode(SuiSendPlan.self,from:$0) }
        }
    }
    public func journalSuiSignature(sendID: String, signed: SuiSignedSend) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "queued", send.networkID == "sui",
                  let bytes = try Data.fetchOne(db,sql:"SELECT plan FROM suiSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(SuiSendPlan.self,from:bytes)
            try plan.validate()
            guard plan.network == .mainnet, signed.bytes == (try plan.transactionBytes()), send.amountAtomic == String(plan.amount),
                  send.recipient == plan.recipient, try SuiIdentity.address(send.senderAddress) == plan.sender else { throw SuiSendError.changed }
            try SuiSendCrypto.verify(signed,sender:plan.sender)
            let now = Date.now.timeIntervalSince1970, id = "sui:"+signed.digest
            try TransactionRecord(id:id,networkID:"sui",hash:signed.digest,state:"pending",timestamp:now,
                                  feeAtomic:String(plan.estimatedFee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.digest+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,
                networkID:"sui",transactionID:id,assetID:send.assetID,direction:plan.sender == plan.recipient ? "self":"outgoing",
                amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            send.signedPayload = try JSONEncoder().encode(signed); send.transactionID = id; send.state = "signed"; send.updatedAt = now
            try send.update(db)
        }
    }
    /// Only certified execution effects settle an unknown broadcast. Missing
    /// indexer data, timeouts and expired quotes never release a signed send.
    public func settleSuiSend(sendID: String, receipt: SuiSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.networkID == "sui",
                  ["signed","broadcast","confirmed","failed"].contains(send.state),
                  send.transactionID == "sui:"+receipt.digest, let raw = send.signedPayload else { throw StoreError.invalidTransition }
            let signed = try JSONDecoder().decode(SuiSignedSend.self,from:raw)
            guard signed.digest == receipt.digest else { throw SuiSendError.changed }
            try SuiSendCrypto.verify(signed,sender:send.senderAddress)
            let state = receipt.outcome == .confirmed ? "confirmed":"failed"
            guard !["confirmed","failed"].contains(send.state) || send.state == state else { throw StoreError.invalidTransition }
            guard var tx = try TransactionRecord.fetchOne(db,key:"sui:"+receipt.digest) else { throw StoreError.missingRecord }
            tx.state = state; tx.feeAtomic = receipt.fee.map(String.init); tx.updatedAt = Date.now.timeIntervalSince1970
            try tx.update(db)
            send.state = state; send.failureCode = state == "failed" ? "executionFailed":nil; send.updatedAt = tx.updatedAt
            try send.update(db)
            try db.execute(sql:"INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)",arguments:[sendID])
        }
    }
}
