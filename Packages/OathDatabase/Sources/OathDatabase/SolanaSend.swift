import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func solanaSigningAccount(accountID:String) async throws -> AccountRecord {
        try await pool.read { db in
            guard var account=try AccountRecord.fetchOne(db,key:accountID),account.networkID=="solana" else { throw StoreError.missingRecord }
            if let row=try Row.fetchOne(db,sql:"SELECT address,path FROM solanaReceiveAddresses WHERE accountID=? AND isSelected=1",arguments:[accountID]) {
                account.address=row["address"];account.derivationPath=row["path"]
            }
            return account
        }
    }
    public func solanaSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard SolanaIdentity.isSignature(hash) else { throw SolanaSendError.changed }
        return try await pool.read { try SendRecord.fetchOne($0,sql:"SELECT * FROM sends WHERE walletID=? AND networkID='solana' AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,"solana:"+hash]) }
    }
    public func solanaSendBalanceIsCurrent(_ send:SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID=="solana",let id=send.transactionID,let tx=try TransactionRecord.fetchOne(db,key:id),let version=tx.blockHeight else { return false }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM solanaSync WHERE accountID=? AND minimumSlot>=? AND owner=? AND failure IS NULL)",arguments:[send.accountID,version,send.senderAddress]) == true
        }
    }
    /// Reserve the source across duplicate imports. Balance spending is
    /// serialized; independent quote reads may run concurrently.
    public func queueSolanaSend(sendID:String,plan:SolanaSendPlan) async throws {
        try plan.validate();guard plan.network == .mainnet else { throw SolanaSendError.wrongNetwork }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="draft",send.networkID=="solana",
                  let account=try AccountRecord.fetchOne(db,key:send.accountID),account.walletID==send.walletID,account.networkID=="solana",
                  try Self.solanaOwner(account,db:db)==plan.sender,
                  let asset=try AssetRecord.fetchOne(db,key:send.assetID),asset.networkID=="solana",asset.reference==plan.reference,asset.decimals==plan.decimals,
                  send.recipient==plan.recipient,send.amountAtomic==String(plan.amount) else { throw SolanaSendError.changed }
            guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM sends WHERE networkID='solana' AND senderAddress=? AND state IN ('queued','signed','broadcast'))",arguments:[plan.sender]) != true else { throw SolanaSendError.busy }
            try db.execute(sql:"INSERT INTO solanaSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.senderAddress=plan.sender;send.state="queued";send.updatedAt=Date.now.timeIntervalSince1970;try send.update(db)
        }
    }
    public func solanaSendPlan(sendID:String) async throws -> SolanaSendPlan? {
        try await pool.read { db in try Data.fetchOne(db,sql:"SELECT plan FROM solanaSendPlans WHERE sendID=?",arguments:[sendID]).map { try JSONDecoder().decode(SolanaSendPlan.self,from:$0) } }
    }
    public func journalSolanaSignature(sendID:String,signed:SolanaSignedSend) async throws {
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="queued",send.networkID=="solana",
                  let raw=try Data.fetchOne(db,sql:"SELECT plan FROM solanaSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(SolanaSendPlan.self,from:raw);try plan.validate()
            guard plan.network == .mainnet,send.recipient==plan.recipient,send.amountAtomic==String(plan.amount),send.senderAddress==plan.sender else { throw SolanaSendError.changed }
            try SolanaSendCrypto.verify(signed,plan:plan)
            let now=Date.now.timeIntervalSince1970,id="solana:"+signed.hash
            try TransactionRecord(id:id,networkID:"solana",hash:signed.hash,state:"pending",timestamp:now,feeAtomic:String(plan.transactionFee),updatedAt:now).insert(db)
            if plan.removal == nil {
            try ActivityRecord(id:send.accountID+":"+plan.sender+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,networkID:"solana",transactionID:id,assetID:send.assetID,direction:"outgoing",amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            try db.execute(sql:"INSERT INTO solanaActivity(activityID,owner) VALUES(?,?)",arguments:[send.accountID+":"+plan.sender+":"+signed.hash+":"+plan.reference,plan.sender])
            }
            if let removal=plan.removal { try Self.journalPermissionRemoval(.solana(removal),send:send,db:db) }
            send.signedPayload=try JSONEncoder().encode(signed);send.transactionID=id;send.state="signed";send.updatedAt=now;try send.update(db)
        }
    }
    public func settleSolanaSend(sendID:String,receipt:SolanaSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.networkID=="solana",["signed","broadcast","confirmed","failed"].contains(send.state),send.transactionID=="solana:"+receipt.hash,
                  let payload=send.signedPayload,let raw=try Data.fetchOne(db,sql:"SELECT plan FROM solanaSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(SolanaSendPlan.self,from:raw),signed=try JSONDecoder().decode(SolanaSignedSend.self,from:payload)
            try SolanaSendCrypto.verify(signed,plan:plan);guard signed.hash==receipt.hash else { throw SolanaSendError.changed }
            if receipt.outcome == .accepted {
                guard receipt.fee==nil,receipt.slot==nil,receipt.timestamp==nil else { throw SolanaSendError.changed }
                try db.execute(sql:"UPDATE solanaSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",arguments:[Date.now.timeIntervalSince1970,sendID]);return
            }
            let state=receipt.outcome == .confirmed ? "confirmed":"failed"
            let code:String? = switch receipt.outcome { case .failed:"executionFailed";case .expired:"expired";default:nil }
            guard !["confirmed","failed"].contains(send.state) || (send.state==state && send.failureCode==code) else { throw StoreError.invalidTransition }
            if [.confirmed,.failed].contains(receipt.outcome) {
                guard let fee=receipt.fee,fee<=plan.transactionFee,let version=receipt.slot,version>=plan.slot,version<=UInt64(Int64.max),let timestamp=receipt.timestamp,timestamp.isFinite,timestamp>0 else { throw SolanaSendError.changed }
            } else {
                guard receipt.fee==nil,receipt.slot==nil,receipt.timestamp==nil else { throw SolanaSendError.changed }

            }
            guard var tx=try TransactionRecord.fetchOne(db,key:"solana:"+signed.hash) else { throw StoreError.missingRecord }
            let now=Date.now.timeIntervalSince1970
            tx.state=state;tx.feeAtomic=receipt.fee.map(String.init);tx.blockHeight=receipt.slot.flatMap(Int64.init(exactly:));tx.timestamp=receipt.timestamp ?? tx.timestamp;tx.updatedAt=now;try tx.update(db)
            send.state=state;send.failureCode=code;send.updatedAt=now;try send.update(db)
            if receipt.slot != nil { try db.execute(sql:"INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",arguments:[sendID]) }
        }
    }
    public func reconcileSolanaSend(_ id:String,client:SolanaSendClient) async throws {
        guard let send=try await send(id),["signed","broadcast"].contains(send.state) else { return }
        guard let plan=try await solanaSendPlan(sendID:id),let payload=send.signedPayload,plan.network==client.network else { throw SolanaSendError.changed }
        let signed=try JSONDecoder().decode(SolanaSignedSend.self,from:payload);try SolanaSendCrypto.verify(signed,plan:plan)
        if send.state=="signed" { _ = try await transitionSend(id,from:"signed",to:"broadcast") }
        var receipt=try await client.status(signed,plan:plan)
        if receipt.outcome == .unknown { receipt=try await client.submit(signed,plan:plan) }
        try await settleSolanaSend(sendID:id,receipt:receipt)
    }
}
