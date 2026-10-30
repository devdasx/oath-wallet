import Foundation
import GRDB
import OathAnkr

public struct WalletConnectSolanaSubmission: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "walletConnectSolanaSubmissions"
    public let id: String, walletID: String, accountID: String, chain: String, owner: String, fingerprint: String, signature: String
    public let unsigned: Data, signed: Data
    public let minimumSlot: Int64, createdAt: Double
    public var state: String
}

extension OathDatabase {
    static func migrateWalletConnectSolana(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE walletConnectSolanaSubmissions (
                id TEXT PRIMARY KEY NOT NULL,
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                chain TEXT NOT NULL, owner TEXT NOT NULL, fingerprint TEXT NOT NULL,
                signature TEXT NOT NULL, unsigned BLOB NOT NULL, signed BLOB NOT NULL,
                minimumSlot INTEGER NOT NULL, createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE INDEX wc_solana_pending ON walletConnectSolanaSubmissions(state,createdAt);
            """)
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_walletConnectSolanaSubmissions_\(operation) BEFORE \(operation) ON walletConnectSolanaSubmissions
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
    }
    public func walletConnectSolanaSubmission(_ id: String) async throws -> WalletConnectSolanaSubmission? {
        try await pool.read { try WalletConnectSolanaSubmission.fetchOne($0, key: id) }
    }
    public func pendingWalletConnectSolanaSubmissions() async throws -> [WalletConnectSolanaSubmission] {
        try await pool.read { try WalletConnectSolanaSubmission.fetchAll($0, sql: """
            SELECT s.* FROM walletConnectSolanaSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','accepted','unknown') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectSolana(id: String, walletID: String, accountID: String, request: WalletConnectSolanaRequest, signed: Data) async throws -> WalletConnectSolanaSubmission {
        guard request.broadcasts, request.transactions.count == 1, request.minContextSlot <= UInt64(Int64.max) else { throw SolanaSendError.malformed }
        let tx = request.transactions[0]
        try tx.verifySigned(signed, requireAll: true)
        let signature = SolanaSendCrypto.encode(signed.subdata(in: tx.signatureOffset..<tx.signatureOffset+64))
        return try await pool.write { db in
            if let stored = try WalletConnectSolanaSubmission.fetchOne(db, key: id) {
                guard stored.fingerprint == request.fingerprint, stored.walletID == walletID, stored.accountID == accountID, stored.signed == signed else { throw SolanaSendError.changed }
                return stored
            }
            guard let account = try AccountRecord.fetchOne(db, key: accountID), account.walletID == walletID, account.networkID == "solana",
                  try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)", arguments: [walletID]) == true else { throw SolanaSendError.wrongOwner }
            let selected = try String.fetchOne(db, sql: "SELECT address FROM solanaReceiveAddresses WHERE accountID=? AND isSelected=1", arguments: [accountID]) ?? account.address
            guard selected == request.account else { throw SolanaSendError.changed }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM walletConnectSolanaSubmissions WHERE state IN ('signed','accepted','unknown')") ?? 0 < 32 else { throw SolanaSendError.busy }
            let record = WalletConnectSolanaSubmission(id: id, walletID: walletID, accountID: accountID, chain: request.network.walletConnectChain,
                owner: request.account, fingerprint: request.fingerprint, signature: signature, unsigned: tx.bytes, signed: signed,
                minimumSlot: Int64(request.minContextSlot), createdAt: Date.now.timeIntervalSince1970, state: "signed")
            try record.insert(db); return record
        }
    }
    public func settleWalletConnectSolana(_ id: String, outcome: SolanaSendReceipt.Outcome) async throws {
        try await pool.write { db in
            guard var record = try WalletConnectSolanaSubmission.fetchOne(db, key: id) else { return }
            guard !["confirmed", "failed", "expired"].contains(record.state) else { return }
            record.state = outcome.rawValue; try record.update(db)
        }
    }
}
