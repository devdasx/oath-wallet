import Foundation
import GRDB
import OathAnkr

extension OathDatabase {
    /// Submission UI observes the finality-checked send journal, not a tentative
    /// explorer/history row which can include unconfirmed execution results.
    public func polkadotSubmission(walletID:String,hash:String) async throws -> SendRecord? {
        guard hash.hasPrefix("0x"), hash.count == 66 else { throw PolkadotSendError.changed }
        return try await pool.read { db in
            try SendRecord.fetchOne(db,sql:"SELECT * FROM sends WHERE walletID=? AND networkID='polkadot' AND transactionID=? AND signedPayload IS NOT NULL LIMIT 1",arguments:[walletID,"polkadot:"+hash])
        }
    }

    public func polkadotSendBalanceIsCurrent(_ send: SendRecord) async throws -> Bool {
        try await pool.read { db in
            guard send.networkID == "polkadot", let id = send.transactionID,
                  let tx = try TransactionRecord.fetchOne(db,key:id) else { return false }
            guard let height = tx.blockHeight else { return false }
            return try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM polkadotSync WHERE accountID=? AND height>=? AND observedAt>=?)",arguments:[send.accountID,height,tx.timestamp]) == true
        }
    }
    /// Reserve the sender, including duplicate imports in other wallets. Concurrent sends must not spend the same balance or resources.
    public func queuePolkadotSend(sendID: String, plan: PolkadotSendPlan) async throws {
        guard plan.network == .mainnet else { throw PolkadotSendError.wrongNetwork }
        try await queueValidatedPolkadotSend(sendID:sendID,plan:plan)
    }
    // Public testnet integration tests use the same reservation and journal in
    // their isolated database. The app-facing entry retains its mainnet gate.
    func queueValidatedPolkadotSend(sendID: String, plan: PolkadotSendPlan) async throws {
        try plan.validate()
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "draft", send.networkID == "polkadot",
                  let account = try AccountRecord.fetchOne(db,key:send.accountID), account.walletID == send.walletID,
                  account.networkID == "polkadot", try PolkadotIdentity.address(account.address) == plan.sender,
                  let asset = try AssetRecord.fetchOne(db,key:send.assetID), asset.networkID == "polkadot", asset.reference == plan.reference, asset.decimals == plan.decimals,
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.amount) else { throw PolkadotSendError.changed }
            let others = try SendRecord.fetchAll(db,sql:"SELECT * FROM sends WHERE networkID='polkadot' AND state IN ('queued','signed','broadcast')")
            guard try !others.contains(where:{ try PolkadotIdentity.address($0.senderAddress) == plan.sender }) else { throw PolkadotSendError.busy }
            try db.execute(sql:"INSERT INTO polkadotSendPlans(sendID,plan) VALUES(?,?)",arguments:[sendID,try JSONEncoder().encode(plan)])
            send.state = "queued"; send.updatedAt = Date.now.timeIntervalSince1970
            try send.update(db)
        }
    }
    public func polkadotSendPlan(sendID: String) async throws -> PolkadotSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db,sql:"SELECT plan FROM polkadotSendPlans WHERE sendID=?",arguments:[sendID])
                .map { try JSONDecoder().decode(PolkadotSendPlan.self,from:$0) }
        }
    }
    public func journalPolkadotSignature(sendID: String, signed: PolkadotSignedSend) async throws {
        try await journalPolkadotSignature(sendID:sendID,signed:signed,allowingTestnet:false)
    }
    func journalPolkadotSignature(sendID: String, signed: PolkadotSignedSend, allowingTestnet: Bool) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.state == "queued", send.networkID == "polkadot",
                  let bytes = try Data.fetchOne(db,sql:"SELECT plan FROM polkadotSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(PolkadotSendPlan.self,from:bytes)
            try plan.validate()
            guard (plan.network == .mainnet || allowingTestnet), send.amountAtomic == String(plan.amount),
                  send.recipient == plan.recipient, try PolkadotIdentity.address(send.senderAddress) == plan.sender else { throw PolkadotSendError.changed }
            try PolkadotSendCrypto.verify(signed,plan:plan)
            let now = Date.now.timeIntervalSince1970, id = "polkadot:"+signed.hash
            try TransactionRecord(id:id,networkID:"polkadot",hash:signed.hash,state:"pending",timestamp:now,
                                  feeAtomic:String(plan.fee),updatedAt:now).insert(db)
            try ActivityRecord(id:send.accountID+":"+signed.hash+":"+plan.reference,walletID:send.walletID,accountID:send.accountID,
                networkID:"polkadot",transactionID:id,assetID:send.assetID,direction:plan.sender == plan.recipient ? "self":"outgoing",
                amountAtomic:String(plan.amount),counterparty:plan.recipient,timestamp:now).insert(db)
            send.signedPayload = try JSONEncoder().encode(signed); send.transactionID = id; send.state = "signed"; send.updatedAt = now
            try send.update(db)
        }
    }
    /// Only validated execution or proven ledger-range expiry settles a send.
    /// A timeout or local quote expiration never releases a signed transaction.
    public func settlePolkadotSend(sendID: String, receipt: PolkadotSendReceipt) async throws {
        guard receipt.outcome != .unknown else { return }
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db,key:sendID), send.networkID == "polkadot",
                  ["signed","broadcast","confirmed","failed"].contains(send.state),
                  send.transactionID == "polkadot:"+receipt.hash, let raw = send.signedPayload else { throw StoreError.invalidTransition }
            let signed = try JSONDecoder().decode(PolkadotSignedSend.self,from:raw)
            guard signed.hash == receipt.hash else { throw PolkadotSendError.changed }
            guard let planBytes = try Data.fetchOne(db,sql:"SELECT plan FROM polkadotSendPlans WHERE sendID=?",arguments:[sendID]) else { throw StoreError.missingRecord }
            let plan = try JSONDecoder().decode(PolkadotSendPlan.self,from:planBytes)
            try PolkadotSendCrypto.verify(signed,plan:plan)
            if receipt.outcome == .accepted {
                guard receipt.fee == nil, receipt.block == nil, receipt.extrinsicIndex == nil else { throw PolkadotSendError.changed }
                // Idempotent late acknowledgements cannot regress a terminal send.
                try db.execute(sql:"UPDATE polkadotSendPlans SET submittedAt=COALESCE(submittedAt,?) WHERE sendID=?",
                               arguments:[Date.now.timeIntervalSince1970,sendID])
                return
            }
            if receipt.outcome == .expired {
                guard receipt.fee == nil, receipt.block == nil, receipt.extrinsicIndex == nil else { throw PolkadotSendError.changed }
            } else {
                guard let fee = receipt.fee, (try? NearSendAmount.checked(fee)) == fee, let block = receipt.block, block >= plan.blockHeight else { throw PolkadotSendError.changed }
            }
            let state = receipt.outcome == .confirmed ? "confirmed":"failed"
            guard !["confirmed","failed"].contains(send.state) || send.state == state else { throw StoreError.invalidTransition }
            let failureCode = state == "failed" ? (receipt.outcome == .expired ? "expired":"executionFailed"):nil
            guard send.state != "failed" || send.failureCode == failureCode else { throw StoreError.invalidTransition }
            guard var tx = try TransactionRecord.fetchOne(db,key:"polkadot:"+receipt.hash) else { throw StoreError.missingRecord }
            tx.state = state; tx.feeAtomic = receipt.fee; tx.updatedAt = Date.now.timeIntervalSince1970
            tx.blockHeight = receipt.block.flatMap(Int64.init(exactly:))
            try tx.update(db)
            send.state = state; send.failureCode = failureCode; send.updatedAt = tx.updatedAt
            try send.update(db)
            if let index=receipt.extrinsicIndex, let block=receipt.block {
                guard index >= 0, block < plan.expiresAtHeight else { throw PolkadotSendError.changed }
                let ledgerID="\(block)-\(index)"
                let previous=try String.fetchOne(db,sql:"SELECT ledgerID FROM polkadotSendPlans WHERE sendID=?",arguments:[sendID])
                guard previous == nil || previous == ledgerID else { throw PolkadotSendError.changed }
                try db.execute(sql:"UPDATE polkadotSendPlans SET ledgerID=? WHERE sendID=?",arguments:[ledgerID,sendID])
                let indexedID="polkadot:"+ledgerID
                if let indexed=try TransactionRecord.fetchOne(db,key:indexedID) {
                    let hasTransfers=try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM polkadotEvents WHERE accountID=? AND transactionID=? AND id NOT LIKE 'extrinsic:%')",arguments:[send.accountID,ledgerID]) == true
                    if hasTransfers {
                        try db.execute(sql:"DELETE FROM activity WHERE accountID=? AND transactionID=?",arguments:[send.accountID,tx.id])
                    } else {
                        try db.execute(sql:"DELETE FROM activity WHERE accountID=? AND transactionID=?",arguments:[send.accountID,indexedID])
                    }
                    try db.execute(sql:"UPDATE activity SET transactionID=? WHERE transactionID=?",arguments:[tx.id,indexedID])
                    tx.timestamp=indexed.timestamp;try tx.update(db)
                    try db.execute(sql:"DELETE FROM transactions WHERE id=?",arguments:[indexedID])
                }
            }
            if receipt.outcome != .expired { try db.execute(sql:"INSERT OR IGNORE INTO sendBalanceRefreshes(sendID) VALUES(?)",arguments:[sendID]) }
            else { try db.execute(sql:"UPDATE sendBalanceRefreshes SET completedAt=? WHERE sendID=?",arguments:[tx.updatedAt,sendID]) }
        }
    }
}
