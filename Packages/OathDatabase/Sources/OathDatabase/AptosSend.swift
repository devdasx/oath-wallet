import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func aptosSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard hash.hasPrefix("0x"),hash.count==66 else { throw AptosSendError.changed }
        return try await pool.read { try SendRecord.fetchOne($0,sql:"SELECT * FROM sends WHERE walletID=? AND networkID='aptos' AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,"aptos:"+hash]) }
    }
    public func aptosSendBalanceIsCurrent(_ send:SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID=="aptos",let id=send.transactionID,let tx=try TransactionRecord.fetchOne(db,key:id),let version=tx.blockHeight else { return false }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM aptosSync WHERE accountID=? AND ledgerVersion>=? AND failure IS NULL)",arguments:[send.accountID,version]) == true
        }
    }
    /// Reserve the source across duplicate imports. Sequence numbers and balance
    /// spending are serialized; independent quote reads may run concurrently.
    public func queueAptosSend(sendID:String,plan:AptosSendPlan) async throws {
        try plan.validate();guard plan.network == .mainnet else { throw AptosSendError.wrongNetwork }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="draft",send.networkID=="aptos",
                  let account=try AccountRecord.fetchOne(db,key:send.accountID),account.walletID==send.walletID,account.networkID=="aptos",
                  try AptosIdentity.address(account.address)==plan.sender,
                  let asset=try AssetRecord.fetchOne(db,key:send.assetID),asset.networkID=="aptos",asset.reference==plan.reference,asset.decimals==plan.decimals,
                  send.recipient==plan.recipient,send.amountAtomic==String(plan.amount) else { throw AptosSendError.changed }
            let others=try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='aptos' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{try AptosIdentity.address($0.senderAddress)==plan.sender}) else { throw AptosSendError.busy }
            try db.execute(sql:"INSERT INTO aptosSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state="queued";send.updatedAt=Date.now.timeIntervalSince1970;try send.update(db)
        }
    }
    public func aptosSendPlan(sendID:String) async throws -> AptosSendPlan? {
        try await pool.read { db in try Data.fetchOne(db,sql:"SELECT plan FROM aptosSendPlans WHERE sendID=?",arguments:[sendID]).map { try JSONDecoder().decode(AptosSendPlan.self,from:$0) } }
    }
    public func journalAptosSignature(sendID:String,signed:AptosSignedSend) async throws {
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="queued",send.networkID=="aptos",
                  let raw=try Data.fetchOne(db,sql:"SELECT plan FROM aptosSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(AptosSendPlan.self,from:raw);try plan.validate()
            guard plan.network == .mainnet,send.recipient==plan.recipient,send.amountAtomic==String(plan.amount),try AptosIdentity.address(send.senderAddress)==plan.sender else { throw AptosSendError.changed }
            try AptosSendCrypto.verify(signed,plan:plan)
            let now=Date.now.timeIntervalSince1970,id="aptos:"+signed.hash
            try TransactionRecord(id:id,networkID:"aptos",hash:signed.hash,state:"pending",timestamp:now,feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,networkID:"aptos",transactionID:id,assetID:send.assetID,direction:"outgoing",amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            send.signedPayload=try JSONEncoder().encode(signed);send.transactionID=id;send.state="signed";send.updatedAt=now;try send.update(db)
        }
    }
    public func settleAptosSend(sendID:String,receipt:AptosSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.networkID=="aptos",["signed","broadcast","confirmed","failed"].contains(send.state),send.transactionID=="aptos:"+receipt.hash,
                  let payload=send.signedPayload,let raw=try Data.fetchOne(db,sql:"SELECT plan FROM aptosSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(AptosSendPlan.self,from:raw),signed=try JSONDecoder().decode(AptosSignedSend.self,from:payload)
            try AptosSendCrypto.verify(signed,plan:plan);guard signed.hash==receipt.hash else { throw AptosSendError.changed }
            if receipt.outcome == .accepted {
                guard receipt.fee==nil,receipt.version==nil,receipt.replacementHash==nil else { throw AptosSendError.changed }
                try db.execute(sql:"UPDATE aptosSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",arguments:[Date.now.timeIntervalSince1970,sendID]);return
            }
            let state=receipt.outcome == .confirmed ? "confirmed":"failed"
            let code:String? = switch receipt.outcome { case .failed:"executionFailed";case .expired:"expired";case .replaced:"replaced";default:nil }
            guard !["confirmed","failed"].contains(send.state) || (send.state==state && send.failureCode==code) else { throw StoreError.invalidTransition }
            if [.confirmed,.failed].contains(receipt.outcome) {
                guard let fee=receipt.fee,fee<=plan.fee,let version=receipt.version,version<=UInt64(Int64.max),let timestamp=receipt.timestamp,timestamp.isFinite,timestamp>0,receipt.replacementHash==nil else { throw AptosSendError.changed }
            } else {
                guard receipt.fee==nil,receipt.version==nil,receipt.timestamp==nil else { throw AptosSendError.changed }
                if receipt.outcome == .replaced { guard let hash=receipt.replacementHash,hash != signed.hash,hash.hasPrefix("0x"),hash.count==66,try TronIdentity.hex(hash).count==32 else { throw AptosSendError.changed } }
                else { guard receipt.replacementHash==nil else { throw AptosSendError.changed } }
            }
            guard var tx=try TransactionRecord.fetchOne(db,key:"aptos:"+signed.hash) else { throw StoreError.missingRecord }
            let now=Date.now.timeIntervalSince1970
            tx.state=receipt.outcome == .replaced ? "replaced":state;tx.feeAtomic=receipt.fee.map(String.init);tx.blockHeight=receipt.version.flatMap(Int64.init(exactly:));tx.timestamp=receipt.timestamp ?? tx.timestamp;tx.updatedAt=now;try tx.update(db)
            if let hash=receipt.replacementHash {
                try db.execute(sql:"INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,replacementHash,outcomeAt) VALUES(?,?,?,0,'replaced',?,?) ON CONFLICT(accountID,transactionID) DO UPDATE SET outcome='replaced',replacementHash=excluded.replacementHash,outcomeAt=excluded.outcomeAt",arguments:[send.accountID,tx.id,try JSONEncoder().encode(Set<String>()),hash,now])
            }
            send.state=state;send.failureCode=code;send.updatedAt=now;try send.update(db)
            if receipt.version != nil { try db.execute(sql:"INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",arguments:[sendID]) }
        }
    }
    public func reconcileAptosSend(_ id:String,client:AptosSendClient) async throws {
        guard let send=try await send(id),["signed","broadcast"].contains(send.state) else { return }
        guard let plan=try await aptosSendPlan(sendID:id),let payload=send.signedPayload,plan.network==client.network else { throw AptosSendError.changed }
        let signed=try JSONDecoder().decode(AptosSignedSend.self,from:payload);try AptosSendCrypto.verify(signed,plan:plan)
        if send.state=="signed" { _ = try await transitionSend(id,from:"signed",to:"broadcast") }
        var receipt=try await client.status(signed,plan:plan)
        if receipt.outcome == .unknown { receipt=try await client.submit(signed,plan:plan) }
        try await settleAptosSend(sendID:id,receipt:receipt)
    }
}
