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

public enum WalletCloudBackupStatus: Equatable, Sendable {
    case unconfirmed, uploading, uploaded

    public func visibleOffer(for pending: WalletBackupOffer?) -> WalletBackupOffer? {
        guard self == .uploaded else { return pending }
        switch pending {
        case .cloudOrManual, .manualOnly: return .manualOnly
        case .cloudOnly, nil: return nil
        }
    }
}

extension OathDatabase {
    /// Observe only the local upload receipt, without reading the encrypted document.
    public func observeBackupOfferStatus(walletID: String) -> AsyncThrowingStream<WalletCloudBackupStatus, Error> {
        stream { db in try Self.backupOfferStatus(db, walletID: walletID) }
    }

    private static func backupOfferStatus(_ db: Database, walletID: String) throws -> WalletCloudBackupStatus {
        guard let record = try Row.fetchOne(db, sql: "SELECT state, enabled, failureCode FROM cloudBackups WHERE walletID = ?", arguments: [walletID]) else {
            return .unconfirmed
        }
        let state: String = record["state"]
        let failure: String? = record["failureCode"]
        guard failure == nil else { return .unconfirmed }
        // Disabling future uploads leaves a confirmed file in iCloud. A confirmed
        // removal changes the stored state to failed in reconcileRemovedCloudBackups.
        if state == "uploaded" { return .uploaded }
        let enabled: Bool = record["enabled"]
        if enabled && (state == "queued" || state == "uploading") { return .uploading }
        return .unconfirmed
    }

    /// Only the caller that consumes an eligible offer may present it.
    public func claimBackupOffer(walletID: String) async throws -> WalletBackupOffer? {
        try await pool.write { db in
            guard let offer = try WalletBackupOffer.fetchOne(db, sql: """
                SELECT pendingBackupOffer FROM wallets WHERE id = ? AND deletedAt IS NULL
                """, arguments: [walletID]),
                  try Self.backupOfferStatus(db, walletID: walletID).visibleOffer(for: offer) != nil else { return nil }
            try db.execute(sql: """
                UPDATE wallets SET pendingBackupOffer = NULL, needsBackupOfferReview = NULL WHERE id = ?
                """, arguments: [walletID])
            return offer
        }
    }

    public func finishBackupOfferReview(walletID: String, previouslyUntrackedOffer: WalletBackupOffer?) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE wallets SET pendingBackupOffer = COALESCE(pendingBackupOffer, ?), needsBackupOfferReview = NULL
                WHERE id = ? AND needsBackupOfferReview = 1
                """, arguments: [previouslyUntrackedOffer, walletID])
        }
    }

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
    /// May narrow an outstanding offer after a matching import, or suppress it after a cloud restore.
    /// A cleared offer stays cleared even when the wallet is imported again.
    public func updatePendingBackupOffer(walletID: String, to offer: WalletBackupOffer?) async throws {
        try await pool.write { db in
            try db.execute(sql: """
                UPDATE wallets SET pendingBackupOffer = ?, needsBackupOfferReview = NULL
                WHERE id = ? AND (pendingBackupOffer IS NOT NULL OR (? IS NULL AND needsBackupOfferReview = 1))
                """, arguments: [offer, walletID, offer])
        }
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
