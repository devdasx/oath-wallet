import Foundation
import CryptoKit
import GRDB
import OathDiagnostics

/// Upgrade input is public metadata only. Keychain references are opaque and
/// must never be put in diagnostics. No legacy balance/history table is read.
public struct LegacyWalletSnapshot: Codable, Equatable, Sendable {
    public let wallets: [LegacyWallet]
    public let accounts: [LegacyAccount]
    public let security: LegacySecurity

    public var activeWalletID: String? { wallets.first(where: \.isSelected)?.id }
    public var fingerprint: String {
        get throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

public struct LegacyWallet: Codable, Equatable, Sendable, FetchableRecord {
    public let id: String
    public let name: String
    public let kind: String
    public let secretKeyReference: String?
    public let isSelected: Bool
    public let sortOrder: Int
    public let createdAt: Double
    public let backupState: String?
    public let recoveryScheme: String?
    public let appearanceColorID: String?
}

public struct LegacyAccount: Codable, Equatable, Sendable, FetchableRecord {
    public let id: String
    public let walletID: String
    public let networkID: String
    public let address: String
    public let normalizedAddress: String
    public let label: String?
    public let derivationPath: String?
    public let accountIndex: Int?
    public let publicKey: String?
    public let isWatchOnly: Bool
    public let isEnabled: Bool
}

public struct LegacySecurity: Codable, Equatable, Sendable {
    public let appLockEnabled: Bool
    public let biometricEnabled: Bool
    public let passcodeReference: String?
    public let failedAttempts: Int
    public let lockedUntil: Double?
    public let autoLockSeconds: Int?
    public let privacyShieldEnabled: Bool
    public let language: String
    public let currency: String
}

public enum LegacyUpgradeError: Error, Equatable, Sendable {
    case invalidSource, missingProtection, ambiguousSelection, unsupportedWallet
    case addressMismatch, sourceChanged, destinationOccupied, conflictingReceipt
    case keyUnavailable, incorrectPasscode, invalidCredential, interrupted
}

/// Opens the shipped database without running either app's schema migrations.
/// A read transaction includes its WAL. File absence alone means clean install;
/// locked, corrupt, incomplete or unfamiliar data always fails closed.
public enum LegacyWalletSource {
    public static func read(at url: URL) async throws -> LegacyWalletSnapshot? {
        try await Task.detached(priority: .userInitiated) { try readSynchronously(at: url) }.value
    }

    static func readSynchronously(at url: URL) throws -> LegacyWalletSnapshot? {
        guard url.isFileURL else { throw LegacyUpgradeError.invalidSource }
        do {
            let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw LegacyUpgradeError.invalidSource }
        } catch CocoaError.fileReadNoSuchFile {
            // Expected clean-install absence, not a failure to report.
            return nil
        }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        configuration.label = "org.oathwallet.legacy.readonly"
        let queue = try DatabaseQueue(path: url.path, configuration: configuration)
        return try queue.read { db in
            guard try db.tableExists("wallets"), try db.tableExists("walletAccounts"),
                  try db.tableExists("userSettings"), try db.tableExists("profileSecurity") else {
                throw LegacyUpgradeError.invalidSource
            }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wallets WHERE archivedAt IS NULL") ?? 0
            guard count <= 10_000 else { throw LegacyUpgradeError.invalidSource }
            // No active wallets in a valid old installation is an empty app.
            guard count > 0 else { return nil }
            let columns = Set(try db.columns(in: "wallets").map(\.name))
            let optional = ["backupState", "recoveryScheme", "appearanceColorID"].map {
                columns.contains($0) ? $0 : "NULL AS \($0)"
            }.joined(separator: ", ")
            let wallets = try LegacyWallet.fetchAll(db, sql: """
                SELECT id, name, kind, secretKeyReference, isSelected, sortOrder, createdAt, \(optional)
                FROM wallets WHERE profileID = 'local-default' AND archivedAt IS NULL
                ORDER BY sortOrder, createdAt, id
                """)
            guard wallets.count == count, Set(wallets.compactMap { UUID(uuidString: $0.id) }).count == count,
                  wallets.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 100 && $0.createdAt.isFinite }) else {
                throw LegacyUpgradeError.invalidSource
            }
            guard wallets.filter(\.isSelected).count == 1 else { throw LegacyUpgradeError.ambiguousSelection }
            let accounts = try LegacyAccount.fetchAll(db, sql: """
                SELECT a.id, a.walletID, a.networkID, a.address, a.normalizedAddress,
                       a.label, a.derivationPath, a.accountIndex, a.publicKey, a.isWatchOnly, a.isEnabled
                FROM walletAccounts a JOIN wallets w ON w.id = a.walletID
                WHERE w.profileID = 'local-default' AND w.archivedAt IS NULL ORDER BY a.walletID, a.id
                """)
            guard accounts.count <= 100_000, wallets.allSatisfy({ wallet in
                accounts.contains(where: { $0.walletID == wallet.id && $0.isEnabled })
            }), accounts.allSatisfy({ !$0.address.isEmpty && ($0.accountIndex ?? 0) >= 0 }) else {
                throw LegacyUpgradeError.invalidSource
            }
            guard let settings = try Row.fetchOne(db, sql: "SELECT * FROM userSettings WHERE profileID = 'local-default'") else {
                throw LegacyUpgradeError.missingProtection
            }
            let security = try Row.fetchOne(db, sql: "SELECT * FROM profileSecurity WHERE profileID = 'local-default'")
            let lock: Bool = settings["appLockEnabled"]
            let biometric: Bool = settings["biometricEnabled"]
            let reference: String? = security?["passcodeKeychainReference"]
            guard (!lock || reference?.isEmpty == false), (!biometric || lock) else { throw LegacyUpgradeError.missingProtection }
            let protection = LegacySecurity(appLockEnabled: lock, biometricEnabled: biometric, passcodeReference: reference,
                failedAttempts: max(0, security?["failedAttemptCount"] ?? 0), lockedUntil: security?["lockedUntil"],
                autoLockSeconds: settings["autoLockSeconds"], privacyShieldEnabled: settings["privacyShieldEnabled"],
                language: settings["languageIdentifier"], currency: settings["currencyCode"])
            // Migration deliberately does not read old address discovery,
            // balances, transaction history or cached network metadata. The
            // new app imports the authenticated recovery material normally.
            return LegacyWalletSnapshot(wallets: wallets, accounts: accounts, security: protection)
        }
    }
}
