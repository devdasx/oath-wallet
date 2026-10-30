import Foundation
import GRDB
import OathAnkr

public struct WalletConnectNearSubmission:Codable,FetchableRecord,PersistableRecord,Sendable {
    public static let databaseTableName = "walletConnectNearSubmissions"
    public let id:String, walletID:String, accountID:String, topic:String, chain:String, owner:String, fingerprint:String
    public let accessData:Data, planData:Data, signedData:Data
    public let createdAt:Double
    public var state:String
    public func decoded() throws -> (WalletConnectNearAccess,WalletConnectNearReview,NearSignedSend) {
        let access = try JSONDecoder().decode(WalletConnectNearAccess.self,from:accessData)
        let plan = try JSONDecoder().decode(WalletConnectNearReview.self,from:planData)
        let signed = try JSONDecoder().decode(NearSignedSend.self,from:signedData)
        guard access.network.walletConnectChain == chain, access.account == owner, access.fingerprint == fingerprint else { throw NearSendError.changed }
        try access.validate(plan); try WalletConnectNearAccess.verify(signed,review:plan)
        return (access,plan,signed)
    }
}
extension OathDatabase {
    static func migrateWalletConnectNear(_ db:Database) throws {
        try db.execute(sql:"""
            CREATE TABLE walletConnectNearSubmissions (
                id TEXT PRIMARY KEY NOT NULL, walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, topic TEXT NOT NULL,
                chain TEXT NOT NULL, owner TEXT NOT NULL, fingerprint TEXT NOT NULL,
                accessData BLOB NOT NULL, planData BLOB NOT NULL, signedData BLOB NOT NULL,
                createdAt DOUBLE NOT NULL, state TEXT NOT NULL
            );
            CREATE INDEX wc_near_pending ON walletConnectNearSubmissions(state,createdAt);
            CREATE TABLE walletConnectNearGrants (
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                topic TEXT NOT NULL, chain TEXT NOT NULL, publicKey BLOB NOT NULL, grantData BLOB NOT NULL,
                PRIMARY KEY(accountID,chain,publicKey)
            );
            """)
        for table in ["walletConnectNearSubmissions","walletConnectNearGrants"] {
            for operation in ["INSERT","UPDATE"] {
                try db.execute(sql:"CREATE TRIGGER reset_guard_\(table)_\(operation) BEFORE \(operation) ON \(table) WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') BEGIN SELECT RAISE(ABORT,'Wallet reset in progress'); END;")
            }
        }
    }
    public func walletConnectNearGrants(walletID:String,accountID:String,topic:String,chain:String) async throws -> [WalletConnectNearGrant] {
        try await pool.read { db in
            try Data.fetchAll(db,sql:"SELECT grantData FROM walletConnectNearGrants WHERE walletID=? AND accountID=? AND topic=? AND chain=?",arguments:[walletID,accountID,topic,chain])
                .map { try JSONDecoder().decode(WalletConnectNearGrant.self,from:$0) }
        }
    }
    public func walletConnectNearSubmission(_ id:String) async throws -> WalletConnectNearSubmission? {
        try await pool.read { try WalletConnectNearSubmission.fetchOne($0,key:id) }
    }
    public func pendingWalletConnectNearSubmissions() async throws -> [WalletConnectNearSubmission] {
        try await pool.read { try WalletConnectNearSubmission.fetchAll($0,sql:"""
            SELECT s.* FROM walletConnectNearSubmissions s JOIN wallets w ON w.id=s.walletID
            WHERE s.state IN ('signed','unknown','accepted') AND w.deletedAt IS NULL
            AND NOT EXISTS(SELECT 1 FROM metadata WHERE key='walletReset') ORDER BY s.createdAt LIMIT 32
            """) }
    }
    public func journalWalletConnectNear(id:String,walletID:String,accountID:String,topic:String,access:WalletConnectNearAccess,plan:WalletConnectNearReview,signed:NearSignedSend) async throws -> WalletConnectNearSubmission {
        try access.validate(plan); try WalletConnectNearAccess.verify(signed,review:plan)
        let accessData = try JSONEncoder().encode(access), planData = try JSONEncoder().encode(plan), signedData = try JSONEncoder().encode(signed)
        return try await pool.write { db in
            if let stored = try WalletConnectNearSubmission.fetchOne(db,key:id) {
                guard stored.fingerprint == access.fingerprint, stored.walletID == walletID, stored.accountID == accountID,
                      stored.topic == topic, try stored.decoded().2 == signed else { throw NearSendError.changed }; return stored
            }
            guard let account = try AccountRecord.fetchOne(db,key:accountID), account.walletID == walletID, account.networkID == "near",
                  account.address == access.account, account.derivationPath != "near-multisig-v1",
                  try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM wallets WHERE id=? AND deletedAt IS NULL)",arguments:[walletID]) == true else { throw NearSendError.wrongOwner }
            guard try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM walletConnectNearSubmissions WHERE state IN ('signed','unknown','accepted')") ?? 0 < 32,
                  try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM walletConnectNearSubmissions WHERE owner=? AND chain=? AND state IN ('signed','unknown','accepted')",arguments:[access.account,access.network.walletConnectChain]) == 0 else { throw NearSendError.busy }
            for key in access.publicKeys {
                let topicStored = try String.fetchOne(db,sql:"SELECT topic FROM walletConnectNearGrants WHERE accountID=? AND chain=? AND publicKey=?",arguments:[accountID,access.network.walletConnectChain,key])
                guard access.method == "near_signIn" ? topicStored == nil : topicStored == topic else { throw NearSendError.wrongOwner }
            }
            if access.network == .mainnet {
                guard try Int.fetchOne(db,sql:"SELECT COUNT(*) FROM sends WHERE networkID='near' AND senderAddress=? AND state IN ('queued','signed','broadcast')",arguments:[access.account]) == 0 else { throw NearSendError.busy }
            }
            let row = WalletConnectNearSubmission(id:id,walletID:walletID,accountID:accountID,topic:topic,chain:access.network.walletConnectChain,owner:access.account,fingerprint:access.fingerprint,accessData:accessData,planData:planData,signedData:signedData,createdAt:Date.now.timeIntervalSince1970,state:"signed")
            try row.insert(db); return row
        }
    }
    public func settleWalletConnectNear(_ id:String,outcome:NearSendReceipt.Outcome) async throws {
        try await pool.write { db in
            guard var row = try WalletConnectNearSubmission.fetchOne(db,key:id), !["confirmed","failed","expired"].contains(row.state) else { return }
            let (access,_,_) = try row.decoded()
            if outcome == .confirmed {
                for key in access.publicKeys {
                    if let receiver = access.receiver {
                        let grant = WalletConnectNearGrant(publicKey:key,receiver:receiver,methodNames:access.methodNames)
                        try db.execute(sql:"INSERT INTO walletConnectNearGrants(walletID,accountID,topic,chain,publicKey,grantData) VALUES(?,?,?,?,?,?)",arguments:[row.walletID,row.accountID,row.topic,row.chain,key,try JSONEncoder().encode(grant)])
                    } else {
                        try db.execute(sql:"DELETE FROM walletConnectNearGrants WHERE walletID=? AND accountID=? AND topic=? AND chain=? AND publicKey=?",arguments:[row.walletID,row.accountID,row.topic,row.chain,key])
                    }
                }
            }
            row.state = outcome.rawValue; try row.update(db)
        }
    }
}
