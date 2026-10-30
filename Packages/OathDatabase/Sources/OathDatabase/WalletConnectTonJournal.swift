import Foundation
import GRDB
import OathAnkr

public struct WalletConnectTonSubmission: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "walletConnectTonSubmissions"
    public let id: String, walletID: String, accountID: String, chain: String, owner: String, fingerprint: String, hash: String
    public let planData: Data, signedData: Data
    public let createdAt: Double
    public var state: String
    public func decoded() throws -> (WalletConnectTonPlan, TonSignedSend) {
        let plan = try JSONDecoder().decode(WalletConnectTonPlan.self, from: planData)
        let signed = try JSONDecoder().decode(TonSignedSend.self, from: signedData)
        guard plan.request.network.walletConnectChain == chain, plan.request.account == owner,
              plan.request.fingerprint == fingerprint, signed.hash == hash else { throw TonSendError.changed }
        try WalletConnectTonCrypto.verify(signed, plan: plan)
        return (plan, signed)
    }
}
extension OathDatabase {
    static func migrateWalletConnectTon(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE walletConnectTonSubmissions (
                id TEXT PRIMARY KEY NOT NULL,
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                chain TEXT NOT NULL, owner TEXT NOT NULL, fingerprint TEXT NOT NULL, hash TEXT NOT NULL,
                planData BLOB NOT NULL, signedData BLOB NOT NULL,
                createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE INDEX wc_ton_pending ON walletConnectTonSubmissions(state,createdAt);
            """)
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_walletConnectTonSubmissions_\(operation) BEFORE \(operation) ON walletConnectTonSubmissions
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
    }
    public func walletConnectTonSubmission(_ id: String) async throws -> WalletConnectTonSubmission? {
        try await pool.read { try WalletConnectTonSubmission.fetchOne($0, key: id) }
    }
    public func pendingWalletConnectTonSubmissions() async throws -> [WalletConnectTonSubmission] {
        try await pool.read { try WalletConnectTonSubmission.fetchAll($0, sql: """
            SELECT s.* FROM walletConnectTonSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','accepted','unknown') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectTon(id: String, walletID: String, accountID: String, plan: WalletConnectTonPlan, signed: TonSignedSend) async throws -> WalletConnectTonSubmission {
        try WalletConnectTonCrypto.verify(signed, plan: plan)
        let planData = try JSONEncoder().encode(plan), signedData = try JSONEncoder().encode(signed)
        return try await pool.write { db in
            if let stored = try WalletConnectTonSubmission.fetchOne(db, key: id) {
                guard stored.fingerprint == plan.request.fingerprint, stored.walletID == walletID,
                      stored.accountID == accountID, try stored.decoded().1 == signed else { throw TonSendError.changed }
                return stored
            }
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.walletID == walletID,
                  account.networkID == "ton", account.derivationPath != "ton-multisig-v1",
                  try TonIdentity.raw(account.address) == plan.request.account,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)", arguments: [walletID]) == true else { throw TonSendError.wrongOwner }
            // One outstanding wallet sequence per network, including ordinary sends.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectTonSubmissions WHERE state IN ('signed','accepted','unknown')") ?? 0 < 32,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectTonSubmissions WHERE owner=? AND chain=? AND state IN ('signed','accepted','unknown')", arguments: [plan.request.account, plan.request.network.walletConnectChain]) == 0 else { throw TonSendError.busy }
            if plan.request.network == .mainnet {
                let sends = try SendRecord.fetchAll(db, sql: "SELECT * FROM sends WHERE networkID='ton' AND state IN ('queued','signed','broadcast')")
                guard try !sends.contains(where: { try TonIdentity.raw($0.senderAddress) == plan.request.account }) else { throw TonSendError.busy }
            }
            let record = WalletConnectTonSubmission(id:id, walletID:walletID, accountID:accountID,
                chain:plan.request.network.walletConnectChain, owner:plan.request.account, fingerprint:plan.request.fingerprint,
                hash:signed.hash, planData:planData, signedData:signedData, createdAt:Date.now.timeIntervalSince1970, state:"signed")
            try record.insert(db); return record
        }
    }
    public func settleWalletConnectTon(_ id: String, outcome: TonSendReceipt.Outcome) async throws {
        try await pool.write { db in
            guard var record = try WalletConnectTonSubmission.fetchOne(db, key:id),
                  !["confirmed","failed","expired"].contains(record.state),
                  !(record.state == "accepted" && outcome == .unknown) else { return }
            record.state = outcome.rawValue; try record.update(db)
        }
    }
}
