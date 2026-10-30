import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    public func pendingXrplMultisigSetup(walletID: String) async throws -> SendRecord? {
        try await pool.read { db in
            let sends = try SendRecord.fetchAll(db, sql: "SELECT s.* FROM sends s JOIN xrplSendPlans p ON p.sendID=s.id WHERE s.walletID=? AND s.networkID='xrpl' AND s.state IN ('queued','signed','broadcast')", arguments: [walletID])
            for send in sends {
                if let bytes = try Data.fetchOne(db, sql: "SELECT plan FROM xrplSendPlans WHERE sendID=?", arguments: [send.id]),
                   try JSONDecoder().decode(XrplSendPlan.self, from: bytes).configuresAccount { return send }
            }
            return nil
        }
    }
    public func xrplSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID == "xrpl", let id = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db,key:id) else { return false }
            return try Bool.fetchOne(db,sql:"""
                SELECT EXISTS(SELECT 1 FROM xrplTransactions t JOIN xrplSync s ON s.accountID=t.accountID
                WHERE t.accountID=? AND t.hash=? AND s.checkpoint>=t.checkpoint AND s.failure IS NULL)
                """,arguments:[send.accountID,tx.hash]) == true
        }
    }
    /// Reserve the sender, including duplicate imports in other wallets. One account sequence must not fund overlapping sends.
    public func queueXrplSend(sendID: String, plan: XrplSendPlan) async throws {
        try plan.validate()
        guard plan.network == .mainnet else { throw XrplSendError.wrongNetwork }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "draft", send.networkID == "xrpl",
                  let account = try AccountRecord.fetchOne(db,key:send.accountID), account.walletID == send.walletID,
                  account.networkID == "xrpl", try XrplIdentity.address(account.address) == plan.sender,
                  let asset = try AssetRecord.fetchOne(db,key:send.assetID), asset.networkID == "xrpl", asset.reference == (plan.configuresAccount ? "native":plan.reference),
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.amount) else { throw XrplSendError.changed }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectXrplSubmissions WHERE source=? AND chain='xrpl:0' AND state IN ('signed','unknown','accepted')", arguments: [plan.sender]) == 0 else { throw XrplSendError.busy }
            let others = try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='xrpl' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{ try XrplIdentity.address($0.senderAddress) == plan.sender }) else { throw XrplSendError.busy }
            try db.execute(sql:"INSERT INTO xrplSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
        }
    }
    public func xrplSendPlan(sendID: String) async throws -> XrplSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db,sql:"SELECT plan FROM xrplSendPlans WHERE sendID=?",arguments:[sendID])
                .map { try JSONDecoder().decode(XrplSendPlan.self,from:$0) }
        }
    }
    public func journalXrplSignature(sendID: String, signed: XrplSignedSend) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "queued", send.networkID == "xrpl",
                  let bytes = try Data.fetchOne(db,sql:"SELECT plan FROM xrplSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(XrplSendPlan.self,from:bytes)
            try plan.validate()
            guard plan.network == .mainnet, send.amountAtomic == String(plan.amount),
                  send.recipient == plan.recipient, try XrplIdentity.address(send.senderAddress) == plan.sender else { throw XrplSendError.changed }
            try XrplSendCrypto.verify(signed,plan:plan)
            let now = Date.now.timeIntervalSince1970, id = "xrpl:"+signed.hash
            try TransactionRecord(id:id,networkID:"xrpl",hash:signed.hash,state:"pending",timestamp:now,
                                  feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            if !plan.configuresAccount {
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,
                networkID:"xrpl",transactionID:id,assetID:send.assetID,direction:plan.sender == plan.recipient ? "self":"outgoing",
                amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            }
            send.signedPayload = try JSONEncoder().encode(signed); send.transactionID = id; send.state = "signed"; send.updatedAt = now
            try send.update(db)
        }
    }
    /// Only validated execution or proven ledger-range expiry settles a send.
    /// A timeout or local quote expiration never releases a signed sequence.
    public func settleXrplSend(sendID: String, receipt: XrplSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.networkID == "xrpl",
                  ["signed","broadcast","confirmed","failed"].contains(send.state),
                  send.transactionID == "xrpl:"+receipt.hash, let raw = send.signedPayload else { throw StoreError.invalidTransition }
            let signed = try JSONDecoder().decode(XrplSignedSend.self,from:raw)
            guard signed.hash == receipt.hash else { throw XrplSendError.changed }
            guard let planBytes = try Data.fetchOne(db,sql:"SELECT plan FROM xrplSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.missingRecord }
            let plan = try JSONDecoder().decode(XrplSendPlan.self,from:planBytes)
            try XrplSendCrypto.verify(signed,plan:plan)
            if receipt.outcome == .accepted {
                guard receipt.fee == nil, receipt.ledger == nil else { throw XrplSendError.changed }
                // Idempotent late acknowledgements cannot regress a terminal send.
                try db.execute(sql:"UPDATE xrplSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",
                               arguments:[Date.now.timeIntervalSince1970,sendID])
                return
            }
            if receipt.outcome == .expired {
                guard receipt.fee == nil, receipt.ledger == nil else { throw XrplSendError.changed }
            } else {
                guard receipt.fee == plan.fee, let ledger = receipt.ledger, (plan.firstLedger...plan.lastLedger).contains(ledger),
                      receipt.outcome == .confirmed ? receipt.code == "tesSUCCESS" : receipt.code?.hasPrefix("tec") == true else { throw XrplSendError.changed }
            }
            let state = receipt.outcome == .confirmed ? "confirmed":"failed"
            guard !["confirmed","failed"].contains(send.state) || send.state == state else { throw StoreError.invalidTransition }
            let failureCode = state == "failed" ? (receipt.outcome == .expired ? "expired":"executionFailed"):nil
            guard send.state != "failed" || send.failureCode == failureCode else { throw StoreError.invalidTransition }
            guard var tx = try TransactionRecord.fetchOne(db,key:"xrpl:"+receipt.hash) else { throw StoreError.missingRecord }
            tx.state = state; tx.feeAtomic = receipt.fee.map(String.init); tx.updatedAt = Date.now.timeIntervalSince1970
            tx.blockHeight = receipt.ledger.map(Int64.init)
            try tx.update(db)
            if plan.closesAccount, receipt.outcome == .confirmed {
                guard let delivered = receipt.deliveredAmount, let drops = UInt64(delivered), drops > 0,
                      drops <= 100_000_000_000_000_000 else { throw XrplSendError.changed }
                // AccountDelete sweeps any XRP arriving before execution too.
                send.amountAtomic = delivered
                try db.execute(sql:"UPDATE activity SET amountAtomic=? WHERE transactionID=? AND accountID=? AND assetID=?",
                    arguments:[delivered,send.transactionID,send.accountID,send.assetID])
            }
            send.state = state; send.failureCode = failureCode; send.updatedAt = tx.updatedAt
            try send.update(db)
            if receipt.outcome != .expired { try db.execute(sql:"INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)",arguments:[sendID]) }
            else { try db.execute(sql:"UPDATE sendBalanceRefreshes SET completedAt=? WHERE sendID=?",arguments:[tx.updatedAt,sendID]) }
        }
    }
}
