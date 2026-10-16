import Foundation
import GRDB
import OathDiagnostics

/// Only derived and verified public records may enter this transaction. The
/// caller commits the encrypted vault first; this batch is kept inside that
/// vault until SQL has committed, making a crash between stores recoverable.
public struct LegacyUpgradeBatch: Codable, Equatable, Sendable {
    public let sourceFingerprint: String
    public let wallets: [WalletRecord]
    public let accounts: [AccountRecord]
    public let activeWalletID: String
    public let settings: [String: String]
    /// Present only for an authenticated replacement of pre-release app data.
    public var replacementID: UUID? = nil

    public init(sourceFingerprint: String, wallets: [WalletRecord], accounts: [AccountRecord],
                activeWalletID: String, settings: [String: String]) {
        self.sourceFingerprint = sourceFingerprint; self.wallets = wallets; self.accounts = accounts
        self.activeWalletID = activeWalletID; self.settings = settings
    }
}

extension OathDatabase {
    /// A receipt, all wallets, all accounts and the initial selection are one
    /// SQLite transaction. A repeated launch cannot replace later user edits or
    /// re-select the old wallet once the migration receipt exists.
    public func commitLegacyUpgrade(_ batch: LegacyUpgradeBatch) async throws {
        let receiptKey = "migration.legacyV1"
        let allowedSettings: Set<String> = ["security.appSwitcherPrivacy", "security.lockDelay", "language", "currency"]
        guard batch.sourceFingerprint.count == 64, batch.sourceFingerprint.allSatisfy(\.isHexDigit),
              !batch.wallets.isEmpty, batch.wallets.count <= 10_000,
              batch.accounts.count <= 100_000,
              Set(batch.wallets.map(\.id)).count == batch.wallets.count,
              Set(batch.accounts.map(\.id)).count == batch.accounts.count,
              batch.wallets.contains(where: { $0.id == batch.activeWalletID }),
              Set(batch.settings.keys).isSubset(of: allowedSettings),
              batch.accounts.allSatisfy({ a in batch.wallets.contains { $0.id == a.walletID } }) else {
            throw LegacyUpgradeError.invalidSource
        }
        try Task.checkCancellation()
        let operationID = OathDiagnostics.operationID ?? UUID()
        try await pool.write { db in
            if let replacementID = batch.replacementID {
                let committed = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key='migration.legacyReplacementV2'")
                if committed != replacementID.uuidString {
                    // The encrypted journal authorizes this replacement. Erasure,
                    // imported rows and receipt share ONE transaction; a failed
                    // import rolls everything back. Never touch the legacy store.
                    try db.execute(sql: "DELETE FROM metadata WHERE key='walletReset'")
                    try Self.eraseWalletRows(db)
                    try db.execute(sql: "DELETE FROM settings")
                }
            }
            if let receipt = try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key=?", arguments: [receiptKey]) {
                if receipt != batch.sourceFingerprint {
                    // A source fingerprint also covers mutable legacy settings
                    // and the reader's schema. An older build/restore can leave
                    // a different receipt beside the same committed wallets.
                    // The receipt alone must not lock an authenticated vault.
                    // Reconcile ONLY a fully committed, identical key/account
                    // projection. Never replace rows or accept partial overlap.
                    OathDiagnostics.$operationID.withValue(operationID) {
                        OathDiagnostics.record(DiagnosticFailure("legacy_receipt_mismatch"),
                            component: "legacy_upgrade", operation: "verify_receipt",
                            context: ["stage": "verify_committed_records"])
                    }
                    try Self.verifyCommittedLegacyIdentity(batch, db: db)
                    try db.execute(sql: "UPDATE settings SET value=?,updatedAt=? WHERE key=?",
                        arguments: [batch.sourceFingerprint, Date().timeIntervalSince1970, receiptKey])
                }
                return
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets") == 0 else {
                throw LegacyUpgradeError.destinationOccupied
            }
            for wallet in batch.wallets {
                guard !wallet.name.isEmpty, wallet.name.count <= 100, wallet.createdAt.isFinite,
                      !wallet.needsCustomization, wallet.deletedAt == nil,
                      ["hd", "imported", "privateKey", "passphrase", "watchOnly"].contains(wallet.kind),
                      batch.accounts.contains(where: { $0.walletID == wallet.id }) else { throw LegacyUpgradeError.invalidSource }
                try wallet.insert(db)
            }
            for account in batch.accounts {
                guard !account.address.isEmpty, !account.derivationPath.isEmpty, account.accountIndex >= 0,
                      account.syncGeneration == 0 else { throw LegacyUpgradeError.invalidSource }
                try account.insert(db)
            }
            for (key, value) in batch.settings {
                try db.execute(sql: "INSERT INTO settings(key,value,updatedAt) VALUES (?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt",
                               arguments: [key, value, Date().timeIntervalSince1970])
            }
            try db.execute(sql: "INSERT INTO settings(key,value,updatedAt) VALUES ('activeWalletID',?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value,updatedAt=excluded.updatedAt",
                           arguments: [batch.activeWalletID, Date().timeIntervalSince1970])
            try db.execute(sql: "INSERT INTO settings(key,value,updatedAt) VALUES (?,?,?)", arguments: [receiptKey, batch.sourceFingerprint, Date().timeIntervalSince1970])
            if let replacementID = batch.replacementID {
                try db.execute(sql: "INSERT INTO settings(key,value,updatedAt) VALUES ('migration.legacyReplacementV2',?,?)",
                    arguments: [replacementID.uuidString, Date().timeIntervalSince1970])
            }
            // Read back every field inside the same transaction before commit.
            guard try WalletRecord.fetchAll(db, sql: "SELECT * FROM wallets ORDER BY id") == batch.wallets.sorted(by: { $0.id < $1.id }),
                  try AccountRecord.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY id") == batch.accounts.sorted(by: { $0.id < $1.id }) else {
                throw LegacyUpgradeError.invalidSource
            }
        }
    }

    private static func verifyCommittedLegacyIdentity(_ batch: LegacyUpgradeBatch, db: Database) throws {
        for expected in batch.wallets {
            guard let stored = try WalletRecord.fetchOne(db, key: expected.id),
                  stored.vaultReference == expected.vaultReference,
                  stored.kind == expected.kind, stored.createdAt == expected.createdAt,
                  stored.deletedAt == expected.deletedAt else {
                throw LegacyUpgradeError.conflictingReceipt
            }
            // Names, order, appearance, backup state and selection belong to
            // the live database. A recovery must not roll back user edits.
        }
        for expected in batch.accounts {
            guard let stored = try AccountRecord.fetchOne(db, key: expected.id),
                  stored.walletID == expected.walletID, stored.networkID == expected.networkID,
                  stored.address == expected.address, stored.derivationPath == expected.derivationPath,
                  stored.accountIndex == expected.accountIndex else {
                throw LegacyUpgradeError.conflictingReceipt
            }
            // Live sync generations and newly enrolled accounts are preserved.
        }
    }
}
