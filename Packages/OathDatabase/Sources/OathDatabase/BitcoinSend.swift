import Foundation
import GRDB
import OathBitcoin

extension OathDatabase {
    public func bitcoinAccount(id: String) async throws -> AccountRecord? {
        try await pool.read { try AccountRecord.fetchOne($0, sql: "SELECT * FROM accounts WHERE id=? AND networkID IN ('bitcoin','litecoin','dogecoin','bitcoincash')", arguments: [id]) }
    }
    /// Reuse unused draft change, while skipping addresses committed to signed
    /// transfers. Repeated reviews must not exhaust a restored wallet's gap.
    /// Mark the chosen address for discovery before anything can be signed.
    public func bitcoinChangeAddress(accountID: String) async throws -> BitcoinDerivedAddress {
        try await pool.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT descriptor FROM bitcoinWallets WHERE accountID=?", arguments: [accountID]) else { throw StoreError.missingRecord }
            let descriptor = try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: data)
            guard [.bitcoin, .bitcoincash, .litecoin, .dogecoin].contains(descriptor.network),
                  let branch = descriptor.branches.first(where: { $0.change == 1 && $0.type == descriptor.defaultType }) ??
                    descriptor.branches.first(where: { $0.change == 1 }) ?? descriptor.branches.first else { throw StoreError.missingRecord }
            let highest = try Int.fetchOne(db, sql: "SELECT MAX(addressIndex) FROM bitcoinAddresses WHERE accountID=? AND branchID=? AND used=1", arguments: [accountID, branch.id]) ?? -1
            let committed = try Data.fetchAll(db, sql: """
                SELECT p.plan FROM bitcoinSendPlans p JOIN sends s ON s.id=p.sendID
                WHERE s.accountID=? AND s.state IN ('signed','broadcast')
                """, arguments: [accountID]).map { try JSONDecoder().decode(BitcoinSendPlan.self, from: $0) }
            let occupied = Set(committed.filter { $0.changeAmount > 0 && $0.change.branchID == branch.id }.map { $0.change.index })
            var next = branch.isHD ? highest + 1 : 0
            if branch.isHD { while next < 100_000, occupied.contains(UInt32(next)) { next += 1 } }
            guard next < 100_000 else { throw StoreError.invalidValue("change index") }
            let index = UInt32(next)
            let address = try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
            try db.execute(sql: """
                INSERT INTO bitcoinAddresses(accountID,branchID,addressIndex,address,script,scriptHash,detail,used,issued)
                VALUES(?,?,?,?,?,?,?,0,1)
                ON CONFLICT(accountID,branchID,addressIndex) DO UPDATE SET issued=1
                """, arguments: [accountID,branch.id,index,address.address,address.script,address.scriptHash,try JSONEncoder().encode(address)])
            return address
        }
    }

    public func saveBitcoinSendPlan(sendID: String, plan: BitcoinSendPlan) async throws {
        try plan.validate()
        guard plan.network == .mainnet else { throw StoreError.invalidValue("send network") }
        try await pool.write { db in
            guard let send = try SendRecord.fetchOne(db, key: sendID), send.state == "draft", send.networkID == plan.chain.rawValue,
                  send.recipient == plan.recipient, send.amountAtomic == String(plan.recipientAmount) else { throw StoreError.conflictingIdentity }
            for coin in plan.coins {
                guard let account = try AccountRecord.fetchOne(db, key: coin.accountID), account.walletID == send.walletID, account.networkID == plan.chain.rawValue else { throw StoreError.conflictingIdentity }
            }
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM bitcoinAddresses WHERE accountID=? AND script=? AND issued=1)", arguments: [send.accountID,plan.change.script]) == true else { throw StoreError.conflictingIdentity }
            try db.execute(sql: "INSERT INTO bitcoinSendPlans(sendID,plan) VALUES(?,?)", arguments: [sendID,try JSONEncoder().encode(plan)])
        }
    }
    public func bitcoinSendPlan(sendID: String) async throws -> BitcoinSendPlan? {
        try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT plan FROM bitcoinSendPlans WHERE sendID=?", arguments: [sendID])
                .map { try JSONDecoder().decode(BitcoinSendPlan.self, from: $0) }
        }
    }

    /// Journal signed bytes and their history identity in one transaction,
    /// before the first network submission. A crash cannot lose reservations.
    public func journalBitcoinSignature(sendID: String, signed: BitcoinSignedSend) async throws {
        try await pool.write { db in
            guard var send = try SendRecord.fetchOne(db, key: sendID), send.state == "queued",
                  let bytes = try Data.fetchOne(db, sql: "SELECT plan FROM bitcoinSendPlans WHERE sendID=?", arguments: [sendID]) else { throw StoreError.invalidTransition }
            let plan = try JSONDecoder().decode(BitcoinSendPlan.self, from: bytes)
            guard send.networkID == plan.chain.rawValue else { throw StoreError.conflictingIdentity }
            try plan.validateSigned(signed)
            let tx = try BitcoinTransactions.details(signed.raw, network: plan.chain)
            let reserved = Set(try Row.fetchAll(db, sql: "SELECT transactionHash,outputIndex FROM utxos WHERE reservedBy=?", arguments: [sendID]).map { "\($0["transactionHash"] as String):\($0["outputIndex"] as Int)" })
            guard tx.inputs.count == plan.coins.count, tx.txid == signed.txid, reserved == Set(plan.coins.map(\.id)), Set(tx.inputs.map(\.outpoint)) == reserved,
                  signed.fee == plan.fee else { throw StoreError.conflictingIdentity }
            let now = Date.now.timeIntervalSince1970, id = plan.chain.rawValue + ":" + signed.txid
            let transaction = TransactionRecord(id: id, networkID: plan.chain.rawValue, hash: signed.txid, state: "pending", timestamp: now,
                                                feeAtomic: String(plan.fee), updatedAt: now)
            try transaction.insert(db)
            try ActivityRecord(id: send.accountID + ":" + id, walletID: send.walletID, accountID: send.accountID,
                               networkID: plan.chain.rawValue, transactionID: id, assetID: plan.chain.rawValue + ":native", direction: "outgoing",
                               amountAtomic: String(plan.recipientAmount), counterparty: plan.recipient, timestamp: now).insert(db)
            // Persist conflict evidence even if a provider never observes our
            // original transfer, so a mined competitor can settle its outcome.
            for accountID in Set(plan.coins.map(\.accountID)).union([send.accountID]) {
                try Self.saveTransactionEvidence(accountID: accountID, tx: transaction,
                    keys: Set(plan.coins.map(\.id)), returnsToWallet: false, db: db)
                try Self.saveBitcoinParticipants(db, accountID: accountID, transactionID: id,
                    addresses: Set(plan.coins.map { $0.address.address }).union([plan.recipient]))
            }
            send.state = "signed"; send.signedPayload = signed.raw; send.transactionID = id; send.updatedAt = now
            try send.update(db)
        }
    }
}

public struct SendDiagnostic: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sendDiagnostics"
    public let id: String, stage: String, code: String, network: String
    public let inputCount: Int, appBuild: Int
    public let createdAt: Double
    public init(stage: String, code: String, inputCount: Int, appBuild: Int, network: String = "bitcoin") {
        self.network = network; self.id = UUID().uuidString; self.stage = stage; self.code = code
        self.inputCount = max(0,min(inputCount,1000)); self.appBuild = max(0,appBuild); self.createdAt = Date.now.timeIntervalSince1970
    }
}
extension OathDatabase {
    public func enqueueSendDiagnostic(_ event: SendDiagnostic) async throws {
        guard ["bitcoin", "bitcoincash", "litecoin", "dogecoin"].contains(event.network),
              ["quote","reserve","authenticate","sign","persist","broadcast","reconcile"].contains(event.stage),
              ["network","storage","changed","expired","insufficientFunds","feeUnavailable","feeTooHigh","invalidInput","invalidRecipient","signing","submissionUnknown","unavailable"].contains(event.code) else { throw StoreError.invalidValue("diagnostic") }
        try await pool.write { db in
            try event.insert(db)
            try db.execute(sql: "DELETE FROM sendDiagnostics WHERE id NOT IN (SELECT id FROM sendDiagnostics ORDER BY createdAt DESC LIMIT 500)")
        }
    }
    public func sendDiagnostics() async throws -> [SendDiagnostic] {
        try await pool.read { try SendDiagnostic.fetchAll($0, sql: "SELECT * FROM sendDiagnostics ORDER BY createdAt LIMIT 50") }
    }
    public func removeSendDiagnostic(id: String) async throws {
        try await pool.write { db in _ = try SendDiagnostic.deleteOne(db, key: id) }
    }
}
