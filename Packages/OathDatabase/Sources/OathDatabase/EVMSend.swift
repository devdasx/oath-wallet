import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    /// A WalletConnect request has a stable hash-based send ID. Authentication
    /// failure may retry only an unsigned draft. Never delete or replace bytes
    /// already journaled for this request, even after cancellation or a restart.
    public func resetUnsentWalletConnectEVM(_ id: String, walletID: String, accountID: String) async throws {
        guard id.hasPrefix("wc:"), id.count == 67, id.dropFirst(3).allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw EVMSendError.changed }
        try await pool.write { db in
            guard let send = try SendRecord.fetchOne(db, key: id) else { return }
            guard send.walletID == walletID, send.accountID == accountID,
                  ["draft", "queued", "cancelled"].contains(send.state),
                  send.signedPayload == nil, send.transactionID == nil else { throw EVMSendError.changed }
            try db.execute(sql: "DELETE FROM sends WHERE id=?", arguments: [id])
        }
    }
    public func evmSubmission(walletID:String,networkID:String,hash:String) async throws -> SendRecord? {
        guard EVMSendNetwork(rawValue:networkID)?.isTestnet == false,AnkrQuantity.hash(hash) else { throw EVMSendError.changed }
        return try await pool.read { try SendRecord.fetchOne($0,sql:"SELECT * FROM sends WHERE walletID=? AND networkID=? AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,networkID,networkID+":"+hash]) }
    }
    public func refreshEVMSendBalance(_ send:SendRecord,client:EVMSendClient) async throws -> Bool {
        guard ["confirmed","failed"].contains(send.state),let plan=try await evmSendPlan(sendID:send.id) else { return false }
        let tx=try await pool.read { try TransactionRecord.fetchOne($0,key:send.transactionID) }
        let minimum=tx?.blockHeight.flatMap(UInt64.init(exactly:)) ?? plan.blockHeight
        let observed=try await client.balancesAfter(plan,minimumHeight:minimum)
        try await pool.write { db in
            guard try SendRecord.fetchOne(db,key:send.id)?.state==send.state else { throw StoreError.staleSync }
            let now=Date.now.timeIntervalSince1970,height=Int64(observed.height)
            // These chains render their dedicated inventory before the generic
            // balance table. Keep both representations current in one write.
            let holdingsTable:String? = switch plan.network {
            case .hyperevm:"hyperevmHoldings"
            case .robinhood:"robinhoodHoldings"
            case .monad,.unichain:"indexedEVMHoldings"
            default:nil
            }
            let accounts=try AccountRecord.fetchAll(db,sql:"SELECT a.* FROM accounts a JOIN wallets w ON w.id=a.walletID WHERE a.networkID=? AND lower(a.address)=? AND w.deletedAt IS NULL",arguments:[send.networkID,plan.sender])
            let assets=try AssetRecord.fetchAll(db,sql:"SELECT * FROM assets WHERE networkID=? AND reference IN ('native',?)",arguments:[send.networkID,plan.reference])
            for account in accounts {
                for asset in assets {
                    let amount=asset.reference=="native" ? observed.native:observed.asset
                    let previous=try Int64.fetchOne(db,sql:"SELECT blockHeight FROM balances WHERE accountID=? AND assetID=?",arguments:[account.id,asset.id])
                    if previous.map({$0<=height}) ?? true {
                        try BalanceRecord(accountID:account.id,assetID:asset.id,networkID:send.networkID,amountAtomic:amount,observedAt:now,blockHeight:height,source:"rpc").upsert(db)
                    }
                    if let table=holdingsTable {
                        // The table name comes only from the fixed switch above.
                        try db.execute(sql:"UPDATE \(table) SET amountAtomic=?,observedAt=?,checkpoint=? WHERE accountID=? AND assetID=? AND checkpoint<=?",arguments:[amount,now,height,account.id,asset.id,height])
                    }
                }
            }
        }
        return true
    }
    /// Reserve unsigned work and each nonce across duplicate imports. A fresh
    /// quote plus preflight can use a later consumed nonce while the previous
    /// signed transaction is still tracked for finality. Never discard its bytes.
    public func queueEVMSend(sendID:String,plan:EVMSendPlan) async throws {
        try plan.validate();guard !plan.network.isTestnet else { throw EVMSendError.wrongNetwork }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="draft",send.networkID==plan.network.rawValue,
                  let account=try AccountRecord.fetchOne(db,key:send.accountID),account.walletID==send.walletID,account.networkID==plan.network.rawValue,
                  try EVMSendIdentity.address(account.address)==plan.sender,
                  let asset=try AssetRecord.fetchOne(db,key:send.assetID),asset.networkID==plan.network.rawValue,asset.reference==plan.reference,asset.decimals==plan.decimals,
                  send.recipient==plan.recipient,send.amountAtomic==String(plan.amount) else { throw EVMSendError.changed }
            let others=try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID=? AND state IN ('queued','signed','broadcast')",arguments:[plan.network.rawValue])
            for other in others where try EVMSendIdentity.address(other.senderAddress)==plan.sender {
                guard other.state != "queued", other.signedPayload != nil,
                      let raw=try Data.fetchOne(db,sql:"SELECT plan FROM evmSendPlans WHERE sendID=?",arguments:[other.id]) else { throw EVMSendError.busy }
                let previous=try JSONDecoder().decode(EVMSendPlan.self,from:raw)
                try previous.validate(checkAge:false)
                // Self-sponsored EIP-7702 removal consumes two nonces.
                let lastNonce=previous.nonce + (previous.removal?.kind == .delegation ? 1:0)
                guard previous.network==plan.network,previous.sender==plan.sender,
                      lastNonce<plan.nonce,previous.blockHeight<=plan.blockHeight else { throw EVMSendError.busy }
            }
            try db.execute(sql:"INSERT INTO evmSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state="queued";send.updatedAt=Date.now.timeIntervalSince1970;try send.update(db)
        }
    }
    public func evmSendPlan(sendID:String) async throws -> EVMSendPlan? {
        try await pool.read { db in try Data.fetchOne(db,sql:"SELECT plan FROM evmSendPlans WHERE sendID=?",arguments:[sendID]).map { try JSONDecoder().decode(EVMSendPlan.self,from:$0) } }
    }
    public func journalEVMSignature(sendID:String,signed:EVMSignedSend) async throws {
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),send.state=="queued",EVMSendNetwork(rawValue:send.networkID)?.isTestnet == false,
                  let raw=try Data.fetchOne(db,sql:"SELECT plan FROM evmSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(EVMSendPlan.self,from:raw);try plan.validate()
            guard !plan.network.isTestnet,send.networkID==plan.network.rawValue,send.recipient==plan.recipient,send.amountAtomic==String(plan.amount),try EVMSendIdentity.address(send.senderAddress)==plan.sender else { throw EVMSendError.changed }
            try EVMSendCrypto.verify(signed,plan:plan)
            let now=Date.now.timeIntervalSince1970,id=plan.network.rawValue+":"+signed.hash
            try TransactionRecord(id:id,networkID:plan.network.rawValue,hash:signed.hash,state:"pending",timestamp:now,feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            if plan.removal == nil {
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,networkID:plan.network.rawValue,transactionID:id,assetID:send.assetID,direction:"outgoing",amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            }
            if let removal=plan.removal { try Self.journalPermissionRemoval(.evm(removal),send:send,db:db) }
            send.signedPayload=try JSONEncoder().encode(signed);send.transactionID=id;send.state="signed";send.updatedAt=now;try send.update(db)
        }
    }
    public func settleEVMSend(sendID:String,receipt:EVMSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send=try SendRecord.fetchOne(db,key:sendID),EVMSendNetwork(rawValue:send.networkID)?.isTestnet == false,["signed","broadcast","confirmed","failed"].contains(send.state),send.transactionID==send.networkID+":"+receipt.hash,
                  let payload=send.signedPayload,let raw=try Data.fetchOne(db,sql:"SELECT plan FROM evmSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan=try JSONDecoder().decode(EVMSendPlan.self,from:raw),signed=try JSONDecoder().decode(EVMSignedSend.self,from:payload)
            try EVMSendCrypto.verify(signed,plan:plan);guard signed.hash==receipt.hash,send.networkID==plan.network.rawValue else { throw EVMSendError.changed }
            if receipt.outcome == .confirmed,plan.reference != "native" {
                guard let delivered=receipt.deliveredAmount else { throw EVMSendError.changed }
                _ = try EVMSendAmount.checked(delivered)
            } else { guard receipt.deliveredAmount==nil else { throw EVMSendError.changed } }
            if receipt.outcome == .accepted {
                guard receipt.fee==nil,receipt.height==nil,receipt.timestamp==nil,receipt.replacementHash==nil else { throw EVMSendError.changed }
                try db.execute(sql:"UPDATE evmSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",arguments:[Date.now.timeIntervalSince1970,sendID]);return
            }
            let state=receipt.outcome == .confirmed ? "confirmed":"failed"
            let code:String? = switch receipt.outcome { case .failed:"executionFailed";case .cancelled:"cancelled";case .replaced:"replaced";default:nil }
            guard !["confirmed","failed"].contains(send.state) || (send.state==state && send.failureCode==code) else { throw StoreError.invalidTransition }
            if [.confirmed,.failed].contains(receipt.outcome) {
                guard let fee=receipt.fee,(![EVMSendNetwork.optimism,.base,.unichain,.scroll].contains(plan.network) ? fee<=plan.fee : true),let version=receipt.height,version>=plan.blockHeight,version<=UInt64(Int64.max),let timestamp=receipt.timestamp,timestamp.isFinite,timestamp>0,receipt.replacementHash==nil else { throw EVMSendError.changed }
            } else {
                guard receipt.fee==nil,receipt.height==nil,receipt.timestamp==nil else { throw EVMSendError.changed }
                if [.replaced,.cancelled].contains(receipt.outcome) { guard let hash=receipt.replacementHash,hash != signed.hash,hash.hasPrefix("0x"),hash.count==66,try TronIdentity.hex(hash).count==32 else { throw EVMSendError.changed } }
                else { guard receipt.replacementHash==nil else { throw EVMSendError.changed } }
            }
            guard var tx=try TransactionRecord.fetchOne(db,key:plan.network.rawValue+":"+signed.hash) else { throw StoreError.missingRecord }
            let now=Date.now.timeIntervalSince1970
            tx.state=[.replaced,.cancelled].contains(receipt.outcome) ? "replaced":state;tx.feeAtomic=receipt.fee.map(String.init);tx.blockHeight=receipt.height.flatMap(Int64.init(exactly:));tx.timestamp=receipt.timestamp ?? tx.timestamp;tx.updatedAt=now;try tx.update(db)
            if let delivered=receipt.deliveredAmount {
                // Only adjust our journal placeholder. Indexed log rows already
                // contain their individual delivered amounts, possibly split.
                try db.execute(sql:"UPDATE activity SET amountAtomic=? WHERE id=?",arguments:[delivered,send.accountID+":"+signed.hash+":"+plan.reference])
            }
            if let hash=receipt.replacementHash {
                try db.execute(sql:"INSERT INTO transactionEvidence(accountID,transactionID,conflictKeys,returnsToWallet,outcome,replacementHash,outcomeAt) VALUES(?,?,?,?,?,?,?) ON CONFLICT(accountID,transactionID) DO UPDATE SET returnsToWallet=excluded.returnsToWallet,outcome=excluded.outcome,replacementHash=excluded.replacementHash,outcomeAt=excluded.outcomeAt",arguments:[send.accountID,tx.id,try JSONEncoder().encode(Set<String>()),receipt.outcome == .cancelled,receipt.outcome == .cancelled ? "canceled":"replaced",hash,now])
            }
            send.state=state;send.failureCode=code;send.updatedAt=now;try send.update(db)
            if receipt.height != nil || receipt.replacementHash != nil { try db.execute(sql:"INSERT INTO sendBalanceRefreshes(sendID) VALUES(?) ON CONFLICT(sendID) DO UPDATE SET completedAt=NULL",arguments:[sendID]) }
        }
    }
    public func reconcileEVMSend(_ id:String,client:EVMSendClient) async throws {
        guard let send=try await send(id),["signed","broadcast"].contains(send.state) else { return }
        guard let plan=try await evmSendPlan(sendID:id),let payload=send.signedPayload,plan.network==client.network else { throw EVMSendError.changed }
        let signed=try JSONDecoder().decode(EVMSignedSend.self,from:payload);try EVMSendCrypto.verify(signed,plan:plan)
        if send.state=="signed" { _ = try await transitionSend(id,from:"signed",to:"broadcast") }
        var receipt=try await client.status(signed,plan:plan)
        if receipt.outcome == .unknown { receipt=try await client.submit(signed,plan:plan) }
        try await settleEVMSend(sendID:id,receipt:receipt)
    }
}
