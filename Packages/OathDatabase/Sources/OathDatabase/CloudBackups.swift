import Foundation
import GRDB

public struct CloudBackupRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "cloudBackups"
    public let walletID: String
    public let backupID: String
    public let accountID: String
    public var enabled: Bool
    public var state: String
    public var encryptedDocument: Data?
    public let createdAt: Double
    public var uploadedAt: Double?
    public var percent: Double?
    public var failureCode: String?

    public init(walletID: String, backupID: UUID, accountID: String, encryptedDocument: Data, createdAt: Date = .now) {
        self.walletID = walletID; self.backupID = backupID.uuidString; self.accountID = accountID
        self.encryptedDocument = encryptedDocument; self.createdAt = createdAt.timeIntervalSince1970
        enabled = true; state = "queued"
    }
}

extension OathDatabase {
    public func cloudBackup(walletID: String) async throws -> CloudBackupRecord? {
        try await pool.read { try CloudBackupRecord.fetchOne($0, key: walletID) }
    }
    public func observeCloudBackup(walletID: String) -> AsyncThrowingStream<CloudBackupRecord?, Error> {
        stream { try CloudBackupRecord.fetchOne($0, key: walletID) }
    }
    public func cloudBackups() async throws -> [CloudBackupRecord] {
        try await pool.read { try CloudBackupRecord.fetchAll($0, sql: "SELECT * FROM cloudBackups WHERE enabled=1") }
    }
    public func observeCloudBackups() -> AsyncThrowingStream<[CloudBackupRecord], Error> {
        stream { try CloudBackupRecord.fetchAll($0, sql: "SELECT * FROM cloudBackups WHERE enabled=1 ORDER BY walletID") }
    }
    /// The durable outbox contains ciphertext only. Committing precedes all
    /// iCloud file writes, so a crash can retry without asking for the password.
    public func queueCloudBackup(_ record: CloudBackupRecord) async throws {
        guard record.state == "queued", record.enabled, !record.accountID.isEmpty,
              let data = record.encryptedDocument, !data.isEmpty, data.count <= 1_048_576 else {
            throw StoreError.invalidValue("cloud backup")
        }
        try await pool.write { db in
            guard let wallet = try WalletRecord.fetchOne(db, key: record.walletID), wallet.deletedAt == nil else {
                throw StoreError.missingRecord
            }
            try record.upsert(db)
        }
    }
    public func disableCloudBackup(walletID: String) async throws {
        try await pool.write { db in
            // Existing iCloud files remain recoverable. Turning off the switch
            // never silently deletes a user's only remote recovery copy.
            try db.execute(sql: "UPDATE cloudBackups SET enabled=0, encryptedDocument=NULL WHERE walletID=?", arguments: [walletID])
        }
    }
    /// A file removed in Files is an expected change, not an upload failure.
    /// Retire its switch once, without retry ciphertext or an error presentation.
    /// Also reconcile the persisted `missing` failures written by older builds
    /// before publishing them to settings. Match a newly observed removal by
    /// backup ID and uploaded state so it cannot disable a replacement upload.
    public func reconcileRemovedCloudBackups(confirmedMissingBackupID: String? = nil) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE cloudBackups
                SET enabled=0, state='failed', encryptedDocument=NULL, percent=NULL, failureCode=NULL
                WHERE failureCode='missing'
                   OR (backupID=? AND enabled=1 AND state='uploaded')
                """, arguments: [confirmedMissingBackupID])
        }
    }
    public func invalidateCloudBackup(backupID: String, failureCode: String) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE cloudBackups SET state='failed', failureCode=? WHERE backupID=? AND enabled=1",
                           arguments: [failureCode, backupID])
        }
    }
    public func updateCloudBackup(backupID: String, state: String, percent: Double? = nil,
                                  failureCode: String? = nil) async throws {
        guard ["uploading", "uploaded", "failed"].contains(state),
              percent.map({ $0.isFinite && (0...100).contains($0) }) ?? true else {
            throw StoreError.invalidValue("cloud backup state")
        }
        try await pool.write { db in
            guard var record = try CloudBackupRecord.fetchOne(db, sql: "SELECT * FROM cloudBackups WHERE backupID=? AND enabled=1", arguments: [backupID]) else { return }
            // A late upload callback cannot downgrade a confirmed backup.
            guard record.state != "uploaded" else { return }
            record.state = state; record.percent = percent; record.failureCode = failureCode
            if state == "uploaded" {
                record.uploadedAt = Date.now.timeIntervalSince1970
                record.percent = 100; record.encryptedDocument = nil; record.failureCode = nil
                try db.execute(sql: "UPDATE wallets SET backedUp=1 WHERE id=?", arguments: [record.walletID])
            }
            try record.update(db)
        }
    }
}
