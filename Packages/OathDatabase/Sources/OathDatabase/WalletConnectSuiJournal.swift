import Foundation
import GRDB
import OathAnkr

public struct WalletConnectSuiSubmission: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "walletConnectSuiSubmissions"
    public let id: String, walletID: String, accountID: String, chain: String, owner: String, fingerprint: String, hash: String
    public let planData: Data, signedData: Data
    public let createdAt: Double
    public var state: String
    public func decoded() throws -> (WalletConnectSuiReview, SuiSignedSend) {
        let plan = try JSONDecoder().decode(WalletConnectSuiReview.self, from: planData)
        let signed = try JSONDecoder().decode(SuiSignedSend.self, from: signedData)
        guard plan.request.network.walletConnectChain == chain, plan.request.account == owner,
              plan.request.fingerprint == fingerprint, signed.digest == hash else { throw SuiSendError.changed }
        guard signed.bytes == plan.request.transaction, plan.request.broadcasts else { throw SuiSendError.changed }
        try SuiSendCrypto.verify(signed, sender: plan.request.account)
        return (plan, signed)
    }
}
extension OathDatabase {
    static func migrateWalletConnectSui(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE walletConnectSuiSubmissions (
                id TEXT PRIMARY KEY NOT NULL,
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                chain TEXT NOT NULL, owner TEXT NOT NULL, fingerprint TEXT NOT NULL, hash TEXT NOT NULL,
                planData BLOB NOT NULL, signedData BLOB NOT NULL,
                createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE INDEX wc_sui_pending ON walletConnectSuiSubmissions(state,createdAt);
            """)
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_walletConnectSuiSubmissions_\(operation) BEFORE \(operation) ON walletConnectSuiSubmissions
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
    }
    public func walletConnectSuiSubmission(_ id: String) async throws -> WalletConnectSuiSubmission? {
        try await pool.read { try WalletConnectSuiSubmission.fetchOne($0, key: id) }
    }
    public func pendingWalletConnectSuiSubmissions() async throws -> [WalletConnectSuiSubmission] {
        try await pool.read { try WalletConnectSuiSubmission.fetchAll($0, sql: """
            SELECT s.* FROM walletConnectSuiSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','unknown') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectSui(id: String, walletID: String, accountID: String, plan: WalletConnectSuiReview, signed: SuiSignedSend) async throws -> WalletConnectSuiSubmission {
        guard signed.bytes == plan.request.transaction, plan.request.broadcasts else { throw SuiSendError.changed }
        try SuiSendCrypto.verify(signed, sender: plan.request.account)
        let planData = try JSONEncoder().encode(plan), signedData = try JSONEncoder().encode(signed)
        return try await pool.write { db in
            if let stored = try WalletConnectSuiSubmission.fetchOne(db, key: id) {
                guard stored.fingerprint == plan.request.fingerprint, stored.walletID == walletID,
                      stored.accountID == accountID, try stored.decoded().1 == signed else { throw SuiSendError.changed }
                return stored
            }
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.walletID == walletID,
                  account.networkID == "sui", account.derivationPath != "sui-multisig-v1",
                  try SuiIdentity.address(account.address) == plan.request.account,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)", arguments: [walletID]) == true else { throw SuiSendError.wrongOwner }
            // Reserve the account while exact signed bytes await execution.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectSuiSubmissions WHERE state IN ('signed','unknown')") ?? 0 < 32,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectSuiSubmissions WHERE owner=? AND chain=? AND state IN ('signed','unknown')", arguments: [plan.request.account, plan.request.network.walletConnectChain]) == 0 else { throw SuiSendError.busy }
            if plan.request.network == .mainnet {
                let sends = try SendRecord.fetchAll(db, sql: "SELECT * FROM sends WHERE networkID='sui' AND state IN ('queued','signed','broadcast')")
                guard try !sends.contains(where: { try SuiIdentity.address($0.senderAddress) == plan.request.account }) else { throw SuiSendError.busy }
            }
            let record = WalletConnectSuiSubmission(id:id, walletID:walletID, accountID:accountID,
                chain:plan.request.network.walletConnectChain, owner:plan.request.account, fingerprint:plan.request.fingerprint,
                hash:signed.digest, planData:planData, signedData:signedData, createdAt:Date.now.timeIntervalSince1970, state:"signed")
            try record.insert(db); return record
        }
    }
    public func settleWalletConnectSui(_ id: String, outcome: SuiSendOutcome) async throws {
        try await pool.write { db in
            guard var record = try WalletConnectSuiSubmission.fetchOne(db, key:id),
                  !["confirmed","failed"].contains(record.state) else { return }
            record.state = outcome.rawValue; try record.update(db)
        }
    }
}
