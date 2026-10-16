import Foundation
import GRDB
import OathAnkr

public struct PermissionRemovalRecord: Codable,FetchableRecord,Sendable,Identifiable,Equatable {
    public let sendID:String,walletID:String,networkID:String,owner:String,revocation:Data,status:String
    public let checkedAt:Double?
    public var id:String { sendID }
    public var operation:PermissionRevocation { get throws { try JSONDecoder().decode(PermissionRevocation.self,from:revocation) } }
}
public struct PermissionRemovalHistory: Sendable,Identifiable,Equatable {
    public let removal:PermissionRemovalRecord,send:SendRecord
    public let transaction:TransactionRecord?
    public let operation:PermissionRevocation
    public var id:String { send.id }
}
extension OathDatabase {
    static func journalPermissionRemoval(_ r:PermissionRevocation,send:SendRecord,db:Database) throws {
        try db.execute(sql:"INSERT INTO permissionRemovals(sendID,walletID,networkID,owner,revocation,status) VALUES(?,?,?,?,?,'pending')",
                       arguments:[send.id,send.walletID,send.networkID,send.senderAddress,try JSONEncoder().encode(r)])
    }
    public func permissionRemoval(sendID:String) async throws -> PermissionRemovalRecord? {
        try await pool.read { try PermissionRemovalRecord.fetchOne($0,sql:"SELECT * FROM permissionRemovals WHERE sendID=?",arguments:[sendID]) }
    }
    public func completePermissionRemoval(sendID:String,removed:Bool) async throws {
        try await pool.write { db in
            guard try SendRecord.fetchOne(db,key:sendID)?.state=="confirmed" else { throw StoreError.invalidTransition }
            try db.execute(sql:"UPDATE permissionRemovals SET status=?,checkedAt=? WHERE sendID=? AND status='pending'",arguments:[removed ? "removed":"active",Date.now.timeIntervalSince1970,sendID])
            try db.execute(sql:"UPDATE permissionBatchItems SET state=? WHERE id=?",arguments:[removed ? "removed":"active",sendID])
            try db.execute(sql:"DELETE FROM sendStatusChecks WHERE sendID=?",arguments:[sendID])
        }
    }
    public func permissionHistory(walletID:String) async throws -> [PermissionRemovalHistory] {
        try await pool.read { try Self.permissionHistory($0,walletID:walletID) }
    }
    public func observePermissionHistory(walletID:String)->AsyncThrowingStream<[PermissionRemovalHistory],Error> {
        stream { try Self.permissionHistory($0,walletID:walletID) }
    }
    private static func permissionHistory(_ db:Database,walletID:String) throws -> [PermissionRemovalHistory] {
        let rows=try PermissionRemovalRecord.fetchAll(db,sql:"SELECT r.* FROM permissionRemovals r JOIN sends s ON s.id=r.sendID WHERE r.walletID=? ORDER BY s.createdAt DESC LIMIT 200",arguments:[walletID])
        return try rows.map { r in guard let send=try SendRecord.fetchOne(db,key:r.sendID) else { throw StoreError.missingRecord };return .init(removal:r,send:send,transaction:try send.transactionID.flatMap{try TransactionRecord.fetchOne(db,key:$0)},operation:try r.operation) }
    }
    public func savePermissionScan(walletID:String,accountID:String,scan:PermissionScan) async throws {
        guard scan.permissions.count<=10_000,scan.checkedAt.timeIntervalSince1970.isFinite,
              scan.permissions.allSatisfy({$0.owner==scan.owner && $0.network==scan.network}) else { throw StoreError.invalidValue("permission scan") }
        try await pool.write { db in
            guard let a=try AccountRecord.fetchOne(db,key:accountID),a.walletID==walletID,a.networkID==scan.network,
                  try WalletRecord.fetchOne(db,key:walletID)?.deletedAt==nil else { throw StoreError.conflictingIdentity }
            let owner=scan.network=="solana" ? try Self.solanaOwner(a,db:db):a.address
            let matches = EVMSendNetwork(rawValue: scan.network) != nil
                ? owner.lowercased() == scan.owner.lowercased() : owner == scan.owner
            guard matches else { throw StoreError.conflictingIdentity }
            try db.execute(sql:"INSERT INTO permissionScans(walletID,accountID,owner,scan) VALUES(?,?,?,?) ON CONFLICT(accountID,owner) DO UPDATE SET scan=excluded.scan",
                           arguments:[walletID,accountID,scan.owner,try JSONEncoder().encode(scan)])
        }
    }
    public func permissionScans(walletID:String) async throws -> [PermissionScan] {
        try await pool.read { db in try Data.fetchAll(db,sql:"SELECT scan FROM permissionScans WHERE walletID=?",arguments:[walletID]).map { try JSONDecoder().decode(PermissionScan.self,from:$0) } }
    }
}
