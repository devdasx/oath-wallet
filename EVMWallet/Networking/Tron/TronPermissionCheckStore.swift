import Foundation
import GRDB

struct TronPermissionCheckRecord: Codable, FetchableRecord, PersistableRecord, Equatable, Sendable {
    static let databaseTableName = "tronPermissionChecks"
    let walletID: String
    let address: String
    let checkedAt: Double
    let state: String
    let permissionIDsJSON: String
    let failureCode: String?

    var showsWarning: Bool {
        state == "multisignature" && failureCode == nil
            && ((try? JSONDecoder().decode([Int].self, from: Data(permissionIDsJSON.utf8)))?.isEmpty == false)
    }

    func showsWarning(for displayedWalletID: String?) -> Bool {
        showsWarning && walletID == displayedWalletID
    }
}

extension WalletDatabase {
    static func registerTronPermissionCheckMigration(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v_tron_permission_checks") { database in
            try database.execute(sql: """
                CREATE TABLE tronPermissionChecks (
                    walletID TEXT PRIMARY KEY NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
                    address TEXT NOT NULL,
                    checkedAt REAL NOT NULL,
                    state TEXT NOT NULL CHECK(state IN ('single', 'multisignature', 'inactive', 'unknown')),
                    permissionIDsJSON TEXT NOT NULL,
                    failureCode TEXT
                )
                """)
        }
    }

    func storeTronPermissionCheck(_ record: TronPermissionCheckRecord) async throws -> Bool {
        try Task.checkCancellation()
        return try await pool.write { db in
            try Task.checkCancellation()
            guard let wallet = try DBWalletRecord.fetchOne(db, key: record.walletID),
                  wallet.archivedAt == nil,
                  TronPermissionMonitor.isEligible(kind: wallet.kind),
                  try DBWalletAccountRecord
                    .filter(Column("walletID") == record.walletID)
                    .filter(Column("networkID") == TronConstants.networkID)
                    .filter(Column("address") == record.address)
                    .filter(Column("isEnabled") == true)
                    .fetchOne(db) != nil else { return false }
            if let previous = try TronPermissionCheckRecord.fetchOne(db, key: record.walletID),
               (previous.showsWarning && previous.address == record.address)
                || previous.checkedAt > record.checkedAt { return false }
            try record.save(db)
            return true
        }
    }
}


extension WalletDatabase {
    /// Only findings tied to a current, enabled account of an imported wallet
    /// may restrict actions. An unrelated or newly created wallet never inherits one.
    static func confirmedTronChecks(in db: Database) throws -> [TronPermissionCheckRecord] {
        try TronPermissionCheckRecord.fetchAll(db, sql: """
            SELECT p.* FROM tronPermissionChecks p
            JOIN wallets w ON w.id = p.walletID
            WHERE w.archivedAt IS NULL
              AND w.kind IN ('importedRecoveryPhrase', 'importedPrivateKey')
              AND p.state = 'multisignature' AND p.failureCode IS NULL
              AND EXISTS (SELECT 1 FROM walletAccounts a
                  WHERE a.walletID = p.walletID AND a.networkID = 'tron'
                    AND a.address = p.address AND a.isEnabled = 1)
            """).filter(\.showsWarning)
    }

    func confirmedTronChecks() -> AsyncValueObservation<[TronPermissionCheckRecord]> {
        ValueObservation.tracking { db in try Self.confirmedTronChecks(in: db) }
            .values(in: pool, bufferingPolicy: .bufferingNewest(1))
    }

    func confirmedTronCheck(walletID: String) async throws -> TronPermissionCheckRecord? {
        try await pool.read { db in
            try Self.confirmedTronChecks(in: db).first { $0.walletID == walletID }
        }
    }
}
