import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func tonSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard (try? TonIdentity.hash(hash)) == hash else { throw TonSendError.changed }
        return try await pool.read { try SendRecord.fetchOne($0,sql:"SELECT sends.* FROM sends JOIN tonSendPlans p ON p.sendID=sends.id WHERE walletID=? AND networkID='ton' AND p.messageHash=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,hash]) }
    }
    public func tonSendBalanceIsCurrent(_ send:SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID=="ton",let id=send.transactionID,let tx=try TransactionRecord.fetchOne(db,key:id),tx.state=="confirmed" || tx.state=="failed" else { return false }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM tonSync WHERE accountID=? AND observedAt>=? AND failure IS NULL)",arguments:[send.accountID,send.updatedAt]) == true
        }
    }
    /// Reserve the source across duplicate imports. Sequence numbers and balance
    /// spending are serialized; independent quote reads may run concurrently.
    public func queueTonSend(sendID:String,plan:TonSendPlan) async throws {
        try plan.validate();guard plan.network == .mainnet else { throw TonSendError.wrongNetwork }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="draft",send.networkID=="ton",
                  let account=try AccountRecord.fetchOne(db,key:send.accountID),account.walletID==send.walletID,account.networkID=="ton",
                  try TonIdentity.raw(account.address)==plan.sender,
                  let asset=try AssetRecord.fetchOne(db,key:send.assetID),asset.networkID=="ton",asset.reference==plan.reference,asset.decimals==plan.decimals,
                  send.recipient==plan.recipient,send.amountAtomic==String(plan.amount) else { throw TonSendError.changed }
            let others=try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='ton' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{try TonIdentity.raw($0.senderAddress)==plan.sender}) else { throw TonSendError.busy }
            try db.execute(sql:"INSERT INTO tonSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state="queued";send.updatedAt=Date.now.timeIntervalSince1970;try send.update(db)
        }
    }
    public func tonSendPlan(sendID:String) async throws -> TonSendPlan? {
        try await pool.read { db in try Data.fetchOne(db,sql:"SELECT plan FROM tonSendPlans WHERE sendID=?",arguments:[sendID]).map { try JSONDecoder().decode(TonSendPlan.self,from:$0) } }
    }
    public func journalTonSignature(sendID:String,signed:TonSignedSend) async throws {
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="queued",send.networkID=="ton",
                  let raw=try Data.fetchOne(db,sql:"SELECT plan FROM tonSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(TonSendPlan.self,from:raw);try plan.validate()
            guard plan.network == .mainnet,send.recipient==plan.recipient,send.amountAtomic==String(plan.amount),try TonIdentity.raw(send.senderAddress)==plan.sender else { throw TonSendError.changed }
            try TonSendCrypto.verify(signed,plan:plan)
            let now=Date.now.timeIntervalSince1970,id="ton:"+signed.hash
            try TransactionRecord(id:id,networkID:"ton",hash:signed.hash,state:"pending",timestamp:now,feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,networkID:"ton",transactionID:id,assetID:send.assetID,direction:"outgoing",amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            try db.execute(sql:"UPDATE tonSendPlans SET messageHash=? WHERE sendID=?",arguments:[signed.hash,sendID])
            send.signedPayload=try JSONEncoder().encode(signed);send.transactionID=id;send.state="signed";send.updatedAt=now;try send.update(db)
        }
    }
    public func settleTonSend(sendID:String,receipt:TonSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.networkID=="ton",["signed","broadcast","confirmed","failed"].contains(send.state),
                  let payload=send.signedPayload,let raw=try Data.fetchOne(db,sql:"SELECT plan FROM tonSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(TonSendPlan.self,from:raw),signed=try JSONDecoder().decode(TonSignedSend.self,from:payload)
            try TonSendCrypto.verify(signed,plan:plan);guard signed.hash==receipt.hash else { throw TonSendError.changed }
            if receipt.outcome == .accepted {
                guard receipt.fee==nil,receipt.lt==nil,receipt.transactionHash==nil else { throw TonSendError.changed }
                try db.execute(sql:"UPDATE tonSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",arguments:[Date.now.timeIntervalSince1970,sendID]);return
            }
            let state=receipt.outcome == .confirmed ? "confirmed":"failed"
            let code:String? = receipt.outcome == .failed ? "executionFailed":receipt.outcome == .expired ? "expired":nil
            guard !["confirmed","failed"].contains(send.state) || (send.state==state && send.failureCode==code) else { throw StoreError.invalidTransition }
            if receipt.outcome != .expired {
                guard let fee=receipt.fee,fee<=plan.nativeBalance,let lt=receipt.lt,lt>0,
                      let time=receipt.timestamp,time.isFinite,time>0,let hash=receipt.transactionHash,try TonIdentity.hash(hash)==hash else { throw TonSendError.changed }
            } else { guard receipt.fee==nil,receipt.lt==nil,receipt.transactionHash==nil else { throw TonSendError.changed } }
            guard let oldID=send.transactionID,var tx=try TransactionRecord.fetchOne(db,key:oldID) else { throw StoreError.missingRecord }
            let now=Date.now.timeIntervalSince1970
            // Keep the durable message identity; map the on-chain hash for history
            // reconciliation and explorer links without breaking foreign keys.
            tx.state=state;tx.feeAtomic=receipt.fee.map(String.init);tx.blockHeight=receipt.lt;tx.timestamp=receipt.timestamp ?? tx.timestamp;tx.updatedAt=now
            if let hash=receipt.transactionHash {
                let newID="ton:"+hash
                tx.id=newID;tx.hash=hash;try tx.upsert(db)
                if oldID != newID {
                    // Indexed history may arrive before the send receipt. Preserve
                    // its movements and remove only the matching local placeholder.
                    try db.execute(sql:"DELETE FROM activity WHERE transactionID=? AND EXISTS(SELECT 1 FROM activity a WHERE a.transactionID=? AND a.accountID=activity.accountID AND a.assetID=activity.assetID AND a.direction=activity.direction AND a.amountAtomic=activity.amountAtomic AND a.counterparty=activity.counterparty)",arguments:[oldID,newID])
                    try db.execute(sql:"UPDATE activity SET transactionID=? WHERE transactionID=?",arguments:[newID,oldID])
                    try db.execute(sql:"UPDATE transfers SET transactionID=? WHERE transactionID=?",arguments:[newID,oldID])
                    send.transactionID=newID;try send.update(db)
                    try db.execute(sql:"DELETE FROM transactions WHERE id=?",arguments:[oldID])
                }
            } else { try tx.update(db) }
            try db.execute(sql:"UPDATE tonSendPlans SET transactionHash=COALESCE(?,transactionHash) WHERE sendID=?",arguments:[receipt.transactionHash,sendID])
            send.state=state;send.failureCode=code;send.updatedAt=now;try send.update(db)
            if receipt.lt != nil { try db.execute(sql:"INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",arguments:[sendID]) }
        }
    }
    public func reconcileTonSend(_ id:String,client:TonSendClient) async throws {
        guard let send=try await send(id),["signed","broadcast"].contains(send.state) else { return }
        guard let plan=try await tonSendPlan(sendID:id),let payload=send.signedPayload,plan.network==client.network else { throw TonSendError.changed }
        let signed=try JSONDecoder().decode(TonSignedSend.self,from:payload);try TonSendCrypto.verify(signed,plan:plan)
        if send.state=="signed" { _ = try await transitionSend(id,from:"signed",to:"broadcast") }
        var receipt=try await client.status(signed,plan:plan)
        if receipt.outcome == .unknown { receipt=try await client.submit(signed,plan:plan) }
        try await settleTonSend(sendID:id,receipt:receipt)
    }
}
