import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func pendingStellarMultisigSetup(walletID: String) async throws -> SendRecord? {
        try await pool.read { db in
            try SendRecord.fetchOne(db, sql: "SELECT * FROM sends WHERE walletID=? AND networkID='stellar' AND state IN ('queued','signed','broadcast') ORDER BY createdAt LIMIT 1", arguments: [walletID])
        }
    }

    public func stellarSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID == "stellar", let id = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db,key:id) else { return false }
            return try Bool.fetchOne(db,sql:"""
                SELECT EXISTS(SELECT 1 FROM stellarTransactions t JOIN stellarSync s ON s.accountID=t.accountID
                WHERE t.accountID=? AND t.hash=? AND s.checkpoint>=t.checkpoint AND s.failure IS NULL)
                """,arguments:[send.accountID,tx.hash]) == true
        }
    }
    /// Reserve the sender, including duplicate imports in other wallets. One account sequence must not fund overlapping sends.
    public func queueStellarSend(sendID: String, plan: StellarSendPlan) async throws {
        try plan.validate()
        guard plan.network == .mainnet else { throw StellarSendError.wrongNetwork }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "draft", send.networkID == "stellar",
                  let account = try AccountRecord.fetchOne(db,key:send.accountID), account.walletID == send.walletID,
                  account.networkID == "stellar", try StellarIdentity.address(account.address) == plan.sender,
                  let asset = try AssetRecord.fetchOne(db,key:send.assetID), asset.networkID == "stellar", asset.reference == (plan.configuresAccount ? "native" : plan.reference), asset.decimals == plan.decimals,
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.amount) else { throw StellarSendError.changed }
            let others = try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='stellar' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{ try StellarIdentity.address($0.senderAddress) == plan.sender }) else { throw StellarSendError.busy }
            try db.execute(sql:"INSERT INTO stellarSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
        }
    }
    public func stellarSendPlan(sendID: String) async throws -> StellarSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db,sql:"SELECT plan FROM stellarSendPlans WHERE sendID=?",arguments:[sendID])
                .map { try JSONDecoder().decode(StellarSendPlan.self,from:$0) }
        }
    }
    public func journalStellarSignature(sendID: String, signed: StellarSignedSend) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "queued", send.networkID == "stellar",
                  let bytes = try Data.fetchOne(db,sql:"SELECT plan FROM stellarSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(StellarSendPlan.self,from:bytes)
            try plan.validate()
            guard plan.network == .mainnet, send.amountAtomic == String(plan.amount),
                  send.recipient == plan.recipient, try StellarIdentity.address(send.senderAddress) == plan.sender else { throw StellarSendError.changed }
            try StellarSendCrypto.verify(signed,plan:plan)
            let now = Date.now.timeIntervalSince1970, id = "stellar:"+signed.hash
            try TransactionRecord(id:id,networkID:"stellar",hash:signed.hash,state:"pending",timestamp:now,
                                  feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            if !plan.configuresAccount {
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,
                networkID:"stellar",transactionID:id,assetID:send.assetID,direction:plan.sender == plan.recipient ? "self":"outgoing",
                amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            }
            send.signedPayload = try JSONEncoder().encode(signed); send.transactionID = id; send.state = "signed"; send.updatedAt = now
            try send.update(db)
        }
    }
    /// Only validated execution or proven ledger-range expiry settles a send.
    /// A timeout or local quote expiration never releases a signed sequence.
    public func settleStellarSend(sendID: String, receipt: StellarSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.networkID == "stellar",
                  ["signed","broadcast","confirmed","failed"].contains(send.state),
                  send.transactionID == "stellar:"+receipt.hash, let raw = send.signedPayload else { throw StoreError.invalidTransition }
            let signed = try JSONDecoder().decode(StellarSignedSend.self,from:raw)
            guard signed.hash == receipt.hash else { throw StellarSendError.changed }
            guard let planBytes = try Data.fetchOne(db,sql:"SELECT plan FROM stellarSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.missingRecord }
            let plan = try JSONDecoder().decode(StellarSendPlan.self,from:planBytes)
            try StellarSendCrypto.verify(signed,plan:plan)
            if receipt.outcome == .accepted {
                guard receipt.fee == nil, receipt.ledger == nil else { throw StellarSendError.changed }
                // Idempotent late acknowledgements cannot regress a terminal send.
                try db.execute(sql:"UPDATE stellarSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",
                               arguments:[Date.now.timeIntervalSince1970,sendID])
                return
            }
            if receipt.outcome == .expired {
                guard receipt.fee == nil, receipt.ledger == nil else { throw StellarSendError.changed }
            } else {
                guard let fee = receipt.fee, fee <= UInt64(plan.fee), let ledger = receipt.ledger, (plan.firstLedger..<plan.lastLedger).contains(ledger) else { throw StellarSendError.changed }
            }
            let state = receipt.outcome == .confirmed ? "confirmed":"failed"
            guard !["confirmed","failed"].contains(send.state) || send.state == state else { throw StoreError.invalidTransition }
            let failureCode = state == "failed" ? (receipt.outcome == .expired ? "expired":"executionFailed"):nil
            guard send.state != "failed" || send.failureCode == failureCode else { throw StoreError.invalidTransition }
            guard var tx = try TransactionRecord.fetchOne(db,key:"stellar:"+receipt.hash) else { throw StoreError.missingRecord }
            tx.state = state; tx.feeAtomic = receipt.fee.map(String.init); tx.updatedAt = Date.now.timeIntervalSince1970
            tx.blockHeight = receipt.ledger.map(Int64.init)
            try tx.update(db)
            send.state = state; send.failureCode = failureCode; send.updatedAt = tx.updatedAt
            try send.update(db)
            if receipt.outcome != .expired { try db.execute(sql:"INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)",arguments:[sendID]) }
            else { try db.execute(sql:"UPDATE sendBalanceRefreshes SET completedAt=? WHERE sendID=?",arguments:[tx.updatedAt,sendID]) }
        }
    }
}
