import Foundation
import GRDB
import OathAnkr

public struct WalletConnectStellarSubmission: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "walletConnectStellarSubmissions"
    public let id: String, walletID: String, accountID: String, chain: String, owner: String, fingerprint: String, hash: String
    public let planData: Data, signedData: Data
    public let createdAt: Double
    public var state: String
    public func decoded() throws -> (WalletConnectStellarReview, WalletConnectStellarSigned) {
        let plan = try JSONDecoder().decode(WalletConnectStellarReview.self, from: planData)
        let signed = try JSONDecoder().decode(WalletConnectStellarSigned.self, from: signedData)
        guard plan.request.network.walletConnectChain == chain, plan.request.account == owner,
              plan.request.fingerprint == fingerprint, signed.hash == hash else { throw StellarSendError.changed }
        guard plan.details == (try plan.request.details()), plan.request.broadcasts else { throw StellarSendError.changed }
        try plan.request.verify(signed)
        return (plan, signed)
    }
}
extension OathDatabase {
    static func migrateWalletConnectStellar(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE walletConnectStellarSubmissions (
                id TEXT PRIMARY KEY NOT NULL,
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                chain TEXT NOT NULL, owner TEXT NOT NULL, fingerprint TEXT NOT NULL, hash TEXT NOT NULL,
                planData BLOB NOT NULL, signedData BLOB NOT NULL,
                createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE INDEX wc_stellar_pending ON walletConnectStellarSubmissions(state,createdAt);
            """)
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_walletConnectStellarSubmissions_\(operation) BEFORE \(operation) ON walletConnectStellarSubmissions
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
    }
    public func walletConnectStellarSubmission(_ id: String) async throws -> WalletConnectStellarSubmission? {
        try await pool.read { try WalletConnectStellarSubmission.fetchOne($0, key: id) }
    }
    public func pendingWalletConnectStellarSubmissions() async throws -> [WalletConnectStellarSubmission] {
        try await pool.read { try WalletConnectStellarSubmission.fetchAll($0, sql: """
            SELECT s.* FROM walletConnectStellarSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','unknown','accepted') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectStellar(id: String, walletID: String, accountID: String, plan: WalletConnectStellarReview, signed: WalletConnectStellarSigned) async throws -> WalletConnectStellarSubmission {
        guard plan.details == (try plan.request.details()), plan.request.broadcasts else { throw StellarSendError.changed }
        try plan.request.verify(signed)
        let planData = try JSONEncoder().encode(plan), signedData = try JSONEncoder().encode(signed)
        return try await pool.write { db in
            if let stored = try WalletConnectStellarSubmission.fetchOne(db, key: id) {
                guard stored.fingerprint == plan.request.fingerprint, stored.walletID == walletID,
                      stored.accountID == accountID, try stored.decoded().1 == signed else { throw StellarSendError.changed }
                return stored
            }
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.walletID == walletID,
                  account.networkID == "stellar", account.derivationPath != "stellar-multisig-v1",
                  try StellarIdentity.address(account.address) == plan.request.account,
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)", arguments: [walletID]) == true else { throw StellarSendError.wrongOwner }
            // Reserve the account while exact signed bytes await execution.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectStellarSubmissions WHERE state IN ('signed','unknown','accepted')") ?? 0 < 32,
                  try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectStellarSubmissions WHERE owner=? AND chain=? AND state IN ('signed','unknown','accepted')", arguments: [plan.request.account, plan.request.network.walletConnectChain]) == 0 else { throw StellarSendError.busy }
            if plan.request.network == .mainnet {
                let sends = try SendRecord.fetchAll(db, sql: "SELECT * FROM sends WHERE networkID='stellar' AND state IN ('queued','signed','broadcast')")
                guard try !sends.contains(where: { try StellarIdentity.address($0.senderAddress) == plan.request.account }) else { throw StellarSendError.busy }
            }
            let record = WalletConnectStellarSubmission(id:id, walletID:walletID, accountID:accountID,
                chain:plan.request.network.walletConnectChain, owner:plan.request.account, fingerprint:plan.request.fingerprint,
                hash:signed.hash, planData:planData, signedData:signedData, createdAt:Date.now.timeIntervalSince1970, state:"signed")
            try record.insert(db); return record
        }
    }
    public func settleWalletConnectStellar(_ id: String, outcome: StellarSendReceipt.Outcome) async throws {
        try await pool.write { db in
            guard var record = try WalletConnectStellarSubmission.fetchOne(db, key:id),
                  !["confirmed","failed","expired"].contains(record.state) else { return }
            if record.state == "accepted", outcome == .unknown { return }
            record.state = outcome.rawValue; try record.update(db)
        }
    }
}
