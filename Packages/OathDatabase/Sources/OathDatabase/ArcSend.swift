import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func arcSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard hash.hasPrefix("0x"),hash.count==66 else { throw ArcSendError.changed }
        return try await pool.read { try SendRecord.fetchOne($0,sql:"SELECT * FROM sends WHERE walletID=? AND networkID='arc' AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,"arc:"+hash]) }
    }
    public func arcSendBalanceIsCurrent(_ send:SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID=="arc",let id=send.transactionID,let tx=try TransactionRecord.fetchOne(db,key:id) else { return false }
            if ["replaced","cancelled"].contains(send.failureCode ?? "") {
                return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM arcSync WHERE accountID=? AND observedAt>=? AND failure IS NULL)",arguments:[send.accountID,send.updatedAt]) == true
            }
            guard let version=tx.blockHeight else { return false }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM arcSync WHERE accountID=? AND checkpoint>=? AND failure IS NULL)",arguments:[send.accountID,version]) == true
        }
    }
    /// Reserve the source across duplicate imports. Sequence numbers and balance
    /// spending are serialized; independent quote reads may run concurrently.
    public func queueArcSend(sendID:String,plan:ArcSendPlan) async throws {
        try plan.validate();guard plan.network == .mainnet else { throw ArcSendError.wrongNetwork }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="draft",send.networkID=="arc",
                  let account=try AccountRecord.fetchOne(db,key:send.accountID),account.walletID==send.walletID,account.networkID=="arc",
                  try ArcIdentity.address(account.address)==plan.sender,
                  let asset=try AssetRecord.fetchOne(db,key:send.assetID),asset.networkID=="arc",asset.reference==plan.reference,asset.decimals==plan.decimals,
                  send.recipient==plan.recipient,send.amountAtomic==String(plan.amount) else { throw ArcSendError.changed }
            let others=try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='arc' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{try ArcIdentity.address($0.senderAddress)==plan.sender}) else { throw ArcSendError.busy }
            try db.execute(sql:"INSERT INTO arcSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state="queued";send.updatedAt=Date.now.timeIntervalSince1970;try send.update(db)
        }
    }
    public func arcSendPlan(sendID:String) async throws -> ArcSendPlan? {
        try await pool.read { db in try Data.fetchOne(db,sql:"SELECT plan FROM arcSendPlans WHERE sendID=?",arguments:[sendID]).map { try JSONDecoder().decode(ArcSendPlan.self,from:$0) } }
    }
    public func journalArcSignature(sendID:String,signed:ArcSignedSend) async throws {
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="queued",send.networkID=="arc",
                  let raw=try Data.fetchOne(db,sql:"SELECT plan FROM arcSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(ArcSendPlan.self,from:raw);try plan.validate()
            guard plan.network == .mainnet,send.recipient==plan.recipient,send.amountAtomic==String(plan.amount),try ArcIdentity.address(send.senderAddress)==plan.sender else { throw ArcSendError.changed }
            try ArcSendCrypto.verify(signed,plan:plan)
            let now=Date.now.timeIntervalSince1970,id="arc:"+signed.hash
            try TransactionRecord(id:id,networkID:"arc",hash:signed.hash,state:"pending",timestamp:now,feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,networkID:"arc",transactionID:id,assetID:send.assetID,direction:"outgoing",amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            send.signedPayload=try JSONEncoder().encode(signed);send.transactionID=id;send.state="signed";send.updatedAt=now;try send.update(db)
        }
    }
    public func settleArcSend(sendID:String,receipt:ArcSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.networkID=="arc",["signed","broadcast","confirmed","failed"].contains(send.state),send.transactionID=="arc:"+receipt.hash,
                  let payload=send.signedPayload,let raw=try Data.fetchOne(db,sql:"SELECT plan FROM arcSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(ArcSendPlan.self,from:raw),signed=try JSONDecoder().decode(ArcSignedSend.self,from:payload)
            try ArcSendCrypto.verify(signed,plan:plan);guard signed.hash==receipt.hash else { throw ArcSendError.changed }
            if receipt.outcome == .confirmed,plan.reference != "native" {
                guard let delivered=receipt.deliveredAmount else { throw ArcSendError.changed }
                _ = try ArcSendAmount.checked(delivered)
            } else { guard receipt.deliveredAmount==nil else { throw ArcSendError.changed } }
            if receipt.outcome == .accepted {
                guard receipt.fee==nil,receipt.height==nil,receipt.timestamp==nil,receipt.replacementHash==nil else { throw ArcSendError.changed }
                try db.execute(sql:"UPDATE arcSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",arguments:[Date.now.timeIntervalSince1970,sendID]);return
            }
            let state=receipt.outcome == .confirmed ? "confirmed":"failed"
            let code:String? = switch receipt.outcome { case .failed:"executionFailed";case .cancelled:"cancelled";case .replaced:"replaced";default:nil }
            guard !["confirmed","failed"].contains(send.state) || (send.state==state && send.failureCode==code) else { throw StoreError.invalidTransition }
            if [.confirmed,.failed].contains(receipt.outcome) {
                guard let fee=receipt.fee,fee<=plan.fee,let version=receipt.height,version>=plan.blockHeight,version<=UInt64(Int64.max),let timestamp=receipt.timestamp,timestamp.isFinite,timestamp>0,receipt.replacementHash==nil else { throw ArcSendError.changed }
            } else {
                guard receipt.fee==nil,receipt.height==nil,receipt.timestamp==nil else { throw ArcSendError.changed }
                if [.replaced,.cancelled].contains(receipt.outcome) { guard let hash=receipt.replacementHash,hash != signed.hash,hash.hasPrefix("0x"),hash.count==66,try TronIdentity.hex(hash).count==32 else { throw ArcSendError.changed } }
                else { guard receipt.replacementHash==nil else { throw ArcSendError.changed } }
            }
            guard var tx=try TransactionRecord.fetchOne(db,key:"arc:"+signed.hash) else { throw StoreError.missingRecord }
            let now=Date.now.timeIntervalSince1970
            tx.state=[.replaced,.cancelled].contains(receipt.outcome) ? "replaced":state;tx.feeAtomic=receipt.fee.map(String.init);tx.blockHeight=receipt.height.flatMap(Int64.init(exactly:));tx.timestamp=receipt.timestamp ?? tx.timestamp;tx.updatedAt=now;try tx.update(db)
            if let delivered=receipt.deliveredAmount {
                try db.execute(sql:"UPDATE activity SET amountAtomic=? WHERE accountID=? AND transactionID=? AND assetID=?",arguments:[delivered,send.accountID,tx.id,send.assetID])
            }
            if let hash=receipt.replacementHash {
                try db.execute(sql:"INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,replacementHash,outcomeAt) VALUES(?,?,?,?,?,?,?) ON CONFLICT(accountID,transactionID) DO UPDATE SET returnsToWallet=excluded.returnsToWallet,outcome=excluded.outcome,replacementHash=excluded.replacementHash,outcomeAt=excluded.outcomeAt",arguments:[send.accountID,tx.id,try JSONEncoder().encode(Set<String>()),receipt.outcome == .cancelled,receipt.outcome == .cancelled ? "canceled":"replaced",hash,now])
            }
            send.state=state;send.failureCode=code;send.updatedAt=now;try send.update(db)
            if receipt.height != nil || receipt.replacementHash != nil { try db.execute(sql:"INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",arguments:[sendID]) }
        }
    }
    public func reconcileArcSend(_ id:String,client:ArcSendClient) async throws {
        guard let send=try await send(id),["signed","broadcast"].contains(send.state) else { return }
        guard let plan=try await arcSendPlan(sendID:id),let payload=send.signedPayload,plan.network==client.network else { throw ArcSendError.changed }
        let signed=try JSONDecoder().decode(ArcSignedSend.self,from:payload);try ArcSendCrypto.verify(signed,plan:plan)
        if send.state=="signed" { _ = try await transitionSend(id,from:"signed",to:"broadcast") }
        var receipt=try await client.status(signed,plan:plan)
        if receipt.outcome == .unknown { receipt=try await client.submit(signed,plan:plan) }
        try await settleArcSend(sendID:id,receipt:receipt)
    }
}
