import Foundation
import GRDB
import OathAnkr

public struct PermissionBatchItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String, batchID: String, walletID: String, accountID: String
    public let permission: WalletPermission
    public let scope: PermissionBatchScope?
    public let ordinal: Int, createdAt: Double
    public var state: String, errorCode: String?
    public var verifiedAt: Double? = nil
    public init(id: String, batchID: String, walletID: String, accountID: String,
                permission: WalletPermission, scope: PermissionBatchScope?, ordinal: Int,
                createdAt: Double, state: String = "queued", errorCode: String? = nil) {
        self.id=id; self.batchID=batchID; self.walletID=walletID; self.accountID=accountID
        self.permission=permission; self.scope=scope; self.ordinal=ordinal; self.createdAt=createdAt
        self.state=state; self.errorCode=errorCode
    }
    public var retryable: Bool { ["failed","paused","active","expired","cancelled","replaced"].contains(state) }
}

extension OathDatabase {
    static func migratePermissionBatches(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE permissionBatchItems (
                id TEXT PRIMARY KEY, batchID TEXT NOT NULL,
                walletID TEXT NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                accountID TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                permissionID TEXT NOT NULL, ordinal INTEGER NOT NULL, createdAt REAL NOT NULL,
                payload BLOB NOT NULL, state TEXT NOT NULL, errorCode TEXT,
                UNIQUE(batchID,ordinal)
            );
            CREATE INDEX permission_batch_wallet ON permissionBatchItems(walletID,createdAt DESC,batchID,ordinal);
            CREATE UNIQUE INDEX permission_batch_active ON permissionBatchItems(walletID,permissionID)
                WHERE state IN ('queued','processing');
            CREATE INDEX permission_batch_identity ON permissionBatchItems(walletID,permissionID,state);
            """)
        for operation in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER reset_guard_permissionBatchItems_\(operation) BEFORE \(operation) ON permissionBatchItems
                WHEN EXISTS(SELECT 1 FROM metadata WHERE key='walletReset')
                BEGIN SELECT RAISE(ABORT, 'Wallet reset in progress'); END;
                """)
        }
    }
    /// Chain resource reservations include duplicate imports of the same owner.
    /// Wait for the existing send to settle before preparing another removal.
    public func permissionBatchCanPrepare(_ scope: PermissionBatchScope) async throws -> Bool {
        try await pool.read { db in
            let owners=try String.fetchAll(db,sql:"SELECT senderAddress FROM sends WHERE networkID=? AND state IN ('queued','signed','broadcast')",arguments:[scope.network])
            return !owners.contains { owner in
                EVMSendNetwork(rawValue:scope.network) != nil ? owner.lowercased()==scope.owner.lowercased():owner==scope.owner
            }
        }
    }
    public func savePermissionBatch(_ items: [PermissionBatchItem]) async throws {
        guard !items.isEmpty, items.count <= PermissionBatchScope.maximumItems, Set(items.map(\.id)).count == items.count,
              Set(items.map(\.batchID)).count == 1, Set(items.map(\.walletID)).count == 1,
              Set(items.map { $0.permission.id }).count == items.count else { throw StoreError.invalidValue("permission batch") }
        try await pool.write { db in
            for item in items {
                guard UUID(uuidString:item.id) != nil, UUID(uuidString:item.batchID) != nil,
                      item.createdAt.isFinite, ["queued","failed","alreadyRemoved"].contains(item.state),
                      let wallet=try WalletRecord.fetchOne(db,key:item.walletID), wallet.deletedAt==nil,
                      let account=try AccountRecord.fetchOne(db,key:item.accountID), account.walletID==item.walletID,
                      account.networkID==item.permission.network else { throw StoreError.conflictingIdentity }
                if item.state == "queued" {
                    guard let scope=item.scope, scope.sendID==item.id, scope.walletID==item.walletID,
                          scope.accountID==item.accountID, scope.network==item.permission.network,
                          scope.owner==item.permission.owner else { throw StoreError.conflictingIdentity }
                }
                guard try Bool.fetchOne(db,sql:"SELECT EXISTS(SELECT 1 FROM permissionBatchItems WHERE walletID=? AND permissionID=? AND state IN ('queued','processing','submitted'))",arguments:[item.walletID,item.permission.id]) != true else { throw StoreError.conflictingIdentity }
                let payload=try JSONEncoder().encode(item)
                guard payload.count <= 65_536 else { throw StoreError.invalidValue("permission batch item") }
                try db.execute(sql:"INSERT INTO permissionBatchItems(id,batchID,walletID,accountID,permissionID,ordinal,createdAt,payload,state,errorCode) VALUES(?,?,?,?,?,?,?,?,?,?)",
                    arguments:[item.id,item.batchID,item.walletID,item.accountID,item.permission.id,item.ordinal,item.createdAt,payload,item.state,item.errorCode])
            }
            // Keep at most ten completed batches per wallet; active work is never pruned.
            try db.execute(sql:"""
                DELETE FROM permissionBatchItems WHERE walletID=? AND batchID NOT IN
                    (SELECT batchID FROM permissionBatchItems WHERE walletID=? GROUP BY batchID ORDER BY MAX(createdAt) DESC LIMIT 10)
                    AND batchID NOT IN (SELECT batchID FROM permissionBatchItems WHERE state IN ('queued','processing','submitted'))
                """,arguments:[items[0].walletID,items[0].walletID])
        }
    }
    public func setPermissionBatchItem(_ id: String, state: String, errorCode: String? = nil) async throws {
        guard ["processing","submitted","failed","paused","alreadyRemoved"].contains(state),
              errorCode == nil || ["changed","insufficient","unsupported","unavailable"].contains(errorCode!) else { throw StoreError.invalidTransition }
        try await pool.write { db in
            try db.execute(sql:"UPDATE permissionBatchItems SET state=?,errorCode=? WHERE id=? AND state IN ('queued','processing')",
                           arguments:[state,errorCode,id])
        }
    }
    /// The signed-byte journal is authoritative, including a kill between signing
    /// and the batch status write. Unsigned interrupted jobs require fresh consent.
    public func reconcilePermissionBatches(walletID: String, interruptUnsigned: Bool) async throws {
        try await pool.write { db in
            try db.execute(sql:"""
                UPDATE permissionBatchItems SET state=CASE
                    WHEN EXISTS(SELECT 1 FROM permissionRemovals r JOIN sends s ON s.id=r.sendID
                        WHERE r.sendID=permissionBatchItems.id AND r.status='removed' AND s.state='confirmed') THEN 'removed'
                    WHEN EXISTS(SELECT 1 FROM permissionRemovals r JOIN sends s ON s.id=r.sendID
                        WHERE r.sendID=permissionBatchItems.id AND r.status='active' AND s.state='confirmed') THEN 'active'
                    WHEN EXISTS(SELECT 1 FROM sends s WHERE s.id=permissionBatchItems.id AND s.state='failed') THEN
                        COALESCE((SELECT failureCode FROM sends s WHERE s.id=permissionBatchItems.id AND failureCode IN ('cancelled','replaced','expired')),'failed')
                    WHEN EXISTS(SELECT 1 FROM sends s WHERE s.id=permissionBatchItems.id AND s.signedPayload IS NOT NULL) THEN 'submitted'
                    WHEN ? AND state IN ('queued','processing') THEN 'paused'
                    ELSE state END
                WHERE walletID=?
                """,arguments:[interruptUnsigned,walletID])
        }
    }
    public func permissionBatchItems(walletID: String) async throws -> [PermissionBatchItem] {
        try await pool.read { try Self.permissionBatchItems($0,walletID:walletID) }
    }
    public func observePermissionBatchItems(walletID: String) -> AsyncThrowingStream<[PermissionBatchItem],Error> {
        stream { try Self.permissionBatchItems($0,walletID:walletID) }
    }
    private static func permissionBatchItems(_ db: Database, walletID: String) throws -> [PermissionBatchItem] {
        try Row.fetchAll(db,sql:"SELECT payload,state,errorCode,(SELECT checkedAt FROM permissionRemovals WHERE sendID=permissionBatchItems.id) AS verifiedAt FROM permissionBatchItems WHERE walletID=? ORDER BY createdAt DESC,ordinal LIMIT 100000",arguments:[walletID]).map { row in
            var item=try JSONDecoder().decode(PermissionBatchItem.self,from:row["payload"])
            item.state=row["state"]; item.errorCode=row["errorCode"]; item.verifiedAt=row["verifiedAt"]
            return item
        }
    }
}
