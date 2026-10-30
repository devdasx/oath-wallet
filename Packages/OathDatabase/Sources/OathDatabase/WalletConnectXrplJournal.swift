import Foundation
import GRDB
import OathAnkr

public struct WalletConnectXrplSubmission: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "walletConnectXrplSubmissions"
    public let id: String, walletID: String, accountID: String, chain: String, owner: String, source: String, fingerprint: String, hash: String
    public let planData: Data, signedData: Data
    public let createdAt: Double
    public var state: String
    public func decoded() throws -> (WalletConnectXrplReview, WalletConnectXrplSigned) {
        let plan = try JSONDecoder().decode(WalletConnectXrplReview.self, from: planData)
        let signed = try JSONDecoder().decode(WalletConnectXrplSigned.self, from: signedData)
        guard plan.request.network.walletConnectChain == chain, plan.request.account == owner, plan.transaction["Account"].string == source,
              plan.request.fingerprint == fingerprint, signed.hash == hash else { throw XrplSendError.changed }
        try plan.validate()
        guard plan.request.broadcasts else { throw XrplSendError.changed }
        try plan.request.verify(signed, review: plan)
        return (plan, signed)
    }
}
extension OathDatabase {
    static func migrateWalletConnectXrpl(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE walletConnectXrplSubmissions (
                id TEXT PRIMARY KEY NOT NULL,
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                chain TEXT NOT NULL, owner TEXT NOT NULL, source TEXT NOT NULL, fingerprint TEXT NOT NULL, hash TEXT NOT NULL,
                planData BLOB NOT NULL, signedData BLOB NOT NULL,
                createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE INDEX wc_xrpl_pending ON walletConnectXrplSubmissions(state,createdAt);
            """)
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_walletConnectXrplSubmissions_\(operation) BEFORE \(operation) ON walletConnectXrplSubmissions
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
    }
    public func walletConnectXrplSubmission(_ id: String) async throws -> WalletConnectXrplSubmission? {
        try await pool.read { try WalletConnectXrplSubmission.fetchOne($0, key: id) }
    }
    public func pendingWalletConnectXrplSubmissions() async throws -> [WalletConnectXrplSubmission] {
        try await pool.read { try WalletConnectXrplSubmission.fetchAll($0, sql: """
            SELECT s.* FROM walletConnectXrplSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','unknown','accepted') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectXrpl(id: String, walletID: String, accountID: String, plan: WalletConnectXrplReview, signed: WalletConnectXrplSigned) async throws -> WalletConnectXrplSubmission {
        try plan.validate()
        guard plan.request.broadcasts else { throw XrplSendError.changed }
        try plan.request.verify(signed, review: plan)
        let planData = try JSONEncoder().encode(plan), signedData = try JSONEncoder().encode(signed)
        return try await pool.write { db in
            if let stored = try WalletConnectXrplSubmission.fetchOne(db, key: id) {
                guard stored.fingerprint == plan.request.fingerprint, stored.walletID == walletID,
                      stored.accountID == accountID, try stored.decoded().1 == signed else { throw XrplSendError.changed }
                return stored
            }
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.walletID == walletID,
                  account.networkID == "xrpl", account.derivationPath != "xrpl-multisig-v1",
                  try XrplIdentity.address(account.address) == plan.request.account,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)", arguments: [walletID]) == true else { throw XrplSendError.wrongOwner }
            // Reserve the account while exact signed bytes await execution.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectXrplSubmissions WHERE state IN ('signed','unknown','accepted')") ?? 0 < 32,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectXrplSubmissions WHERE source=? AND chain=? AND state IN ('signed','unknown','accepted')", arguments: [plan.transaction["Account"].string!, plan.request.network.walletConnectChain]) == 0 else { throw XrplSendError.busy }
            if plan.request.network == .mainnet {
                let sends = try SendRecord.fetchAll(db, sql: "SELECT * FROM sends WHERE networkID='xrpl' AND state IN ('queued','signed','broadcast')")
                guard try !sends.contains(where: { try XrplIdentity.address($0.senderAddress) == plan.transaction["Account"].string }) else { throw XrplSendError.busy }
            }
            let record = WalletConnectXrplSubmission(id:id, walletID:walletID, accountID:accountID,
                chain:plan.request.network.walletConnectChain, owner:plan.request.account, source:plan.transaction["Account"].string!, fingerprint:plan.request.fingerprint,
                hash:signed.hash, planData:planData, signedData:signedData, createdAt:Date.now.timeIntervalSince1970, state:"signed")
            try record.insert(db); return record
        }
    }
    public func settleWalletConnectXrpl(_ id: String, outcome: XrplSendReceipt.Outcome) async throws {
        try await pool.write { db in
            guard var record = try WalletConnectXrplSubmission.fetchOne(db, key:id),
                  !["confirmed","failed","expired"].contains(record.state) else { return }
            if record.state == "accepted", outcome == .unknown { return }
            record.state = outcome.rawValue; try record.update(db)
        }
    }
}
