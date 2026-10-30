import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func thorchainSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard hash.count==64,hash==hash.uppercased(),hash.utf8.allSatisfy({(48...57).contains($0) || (65...70).contains($0)}) else { throw ThorchainSendError.changed }
        return try await pool.read { try SendRecord.fetchOne($0,sql:"SELECT * FROM sends WHERE walletID=? AND networkID='thorchain' AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,"thorchain:"+hash]) }
    }
    public func thorchainSendBalanceIsCurrent(_ send:SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID=="thorchain",let id=send.transactionID,let tx=try TransactionRecord.fetchOne(db,key:id),let height=tx.blockHeight else { return false }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM thorchainSync WHERE accountID=? AND height>=?)",arguments:[send.accountID,height]) == true
        }
    }
    /// Reserve the source across duplicate imports. Sequence numbers and balance
    /// spending are serialized; independent quote reads may run concurrently.
    public func queueThorchainSend(sendID:String,plan:ThorchainSendPlan) async throws {
        try plan.validate();guard plan.network == .mainnet else { throw ThorchainSendError.wrongNetwork }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="draft",send.networkID=="thorchain",
                  let account=try AccountRecord.fetchOne(db,key:send.accountID),account.walletID==send.walletID,account.networkID=="thorchain",
                  try ThorchainIdentity.address(account.address)==plan.sender,
                  let asset=try AssetRecord.fetchOne(db,key:send.assetID),asset.networkID=="thorchain",asset.reference==plan.reference,asset.decimals==plan.decimals,
                  send.recipient==plan.recipient,send.amountAtomic==String(plan.amount) else { throw ThorchainSendError.changed }
            let others=try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='thorchain' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{try ThorchainIdentity.address($0.senderAddress)==plan.sender}) else { throw ThorchainSendError.busy }
            try db.execute(sql:"INSERT INTO thorchainSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state="queued";send.updatedAt=Date.now.timeIntervalSince1970;try send.update(db)
        }
    }
    public func thorchainSendPlan(sendID:String) async throws -> ThorchainSendPlan? {
        try await pool.read { db in try Data.fetchOne(db,sql:"SELECT plan FROM thorchainSendPlans WHERE sendID=?",arguments:[sendID]).map { try JSONDecoder().decode(ThorchainSendPlan.self,from:$0) } }
    }
    public func journalThorchainSignature(sendID:String,signed:ThorchainSignedSend) async throws {
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="queued",send.networkID=="thorchain",
                  let raw=try Data.fetchOne(db,sql:"SELECT plan FROM thorchainSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(ThorchainSendPlan.self,from:raw);try plan.validate()
            guard plan.network == .mainnet,send.recipient==plan.recipient,send.amountAtomic==String(plan.amount),try ThorchainIdentity.address(send.senderAddress)==plan.sender else { throw ThorchainSendError.changed }
            try ThorchainSendCrypto.verify(signed,plan:plan)
            let now=Date.now.timeIntervalSince1970,id="thorchain:"+signed.hash
            try TransactionRecord(id:id,networkID:"thorchain",hash:signed.hash,state:"pending",timestamp:now,feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,networkID:"thorchain",transactionID:id,assetID:send.assetID,direction:"outgoing",amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            send.signedPayload=try JSONEncoder().encode(signed);send.transactionID=id;send.state="signed";send.updatedAt=now;try send.update(db)
        }
    }
    public func settleThorchainSend(sendID:String,receipt:ThorchainSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.networkID=="thorchain",["signed","broadcast","confirmed","failed"].contains(send.state),send.transactionID=="thorchain:"+receipt.hash,
                  let payload=send.signedPayload,let raw=try Data.fetchOne(db,sql:"SELECT plan FROM thorchainSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(ThorchainSendPlan.self,from:raw),signed=try JSONDecoder().decode(ThorchainSignedSend.self,from:payload)
            try ThorchainSendCrypto.verify(signed,plan:plan);guard signed.hash==receipt.hash else { throw ThorchainSendError.changed }
            if receipt.outcome == .accepted {
                guard receipt.fee==nil,receipt.height==nil,receipt.replacementHash==nil else { throw ThorchainSendError.changed }
                try db.execute(sql:"UPDATE thorchainSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",arguments:[Date.now.timeIntervalSince1970,sendID]);return
            }
            let state=receipt.outcome == .confirmed ? "confirmed":"failed"
            let code:String? = switch receipt.outcome { case .failed:"executionFailed";case .expired:"expired";case .replaced:"replaced";default:nil }
            guard !["confirmed","failed"].contains(send.state) || (send.state==state && send.failureCode==code) else { throw StoreError.invalidTransition }
            if [.confirmed,.failed].contains(receipt.outcome) {
                // The quote limit protects approval, but THORChain deducts its native
                // fee at execution. A verified committed receipt must retain the
                // actual fee even when governance changed it after signing.
                guard let fee=receipt.fee,fee>0,let version=receipt.height,version>plan.height,version<=plan.timeoutHeight,let timestamp=receipt.timestamp,timestamp.isFinite,timestamp>0,receipt.replacementHash==nil else { throw ThorchainSendError.changed }
            } else {
                guard receipt.fee==nil,receipt.height==nil,receipt.timestamp==nil else { throw ThorchainSendError.changed }
                if receipt.outcome == .replaced { guard let hash=receipt.replacementHash,hash != signed.hash,hash.count==64,hash==hash.uppercased(),hash.utf8.allSatisfy({(48...57).contains($0) || (65...70).contains($0)}),try TronIdentity.hex(hash).count==32 else { throw ThorchainSendError.changed } }
                else { guard receipt.replacementHash==nil else { throw ThorchainSendError.changed } }
            }
            guard var tx=try TransactionRecord.fetchOne(db,key:"thorchain:"+signed.hash) else { throw StoreError.missingRecord }
            let now=Date.now.timeIntervalSince1970
            tx.state=receipt.outcome == .replaced ? "replaced":state;tx.feeAtomic=receipt.fee.map(String.init);tx.blockHeight=receipt.height.flatMap(Int64.init(exactly:));tx.timestamp=receipt.timestamp ?? tx.timestamp;tx.updatedAt=now;try tx.update(db)
            if let hash=receipt.replacementHash {
                try db.execute(sql:"INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,replacementHash,outcomeAt) VALUES(?,?,?,0,'replaced',?,?) ON CONFLICT(accountID,transactionID) DO UPDATE SET outcome='replaced',replacementHash=excluded.replacementHash,outcomeAt=excluded.outcomeAt",arguments:[send.accountID,tx.id,try JSONEncoder().encode(Set<String>()),hash,now])
            }
            send.state=state;send.failureCode=code;send.updatedAt=now;try send.update(db)
            if receipt.height != nil { try db.execute(sql:"INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",arguments:[sendID]) }
        }
    }
    public func reconcileThorchainSend(_ id:String,client:ThorchainSendClient) async throws {
        guard let send=try await send(id),["signed","broadcast"].contains(send.state) else { return }
        guard let plan=try await thorchainSendPlan(sendID:id),let payload=send.signedPayload,plan.network==client.network else { throw ThorchainSendError.changed }
        let signed=try JSONDecoder().decode(ThorchainSignedSend.self,from:payload);try ThorchainSendCrypto.verify(signed,plan:plan)
        if send.state=="signed" { _ = try await transitionSend(id,from:"signed",to:"broadcast") }
        var receipt=try await client.status(signed,plan:plan)
        if receipt.outcome == .unknown { receipt=try await client.submit(signed,plan:plan) }
        try await settleThorchainSend(sendID:id,receipt:receipt)
    }
}
