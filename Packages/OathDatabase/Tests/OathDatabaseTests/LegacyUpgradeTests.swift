import XCTest
import GRDB
import OathDiagnostics
@testable import OathDatabase

@MainActor final class LegacyUpgradeTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathLegacyTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("wallet.sqlite")
    }
    private func oldDatabase(at url: URL, protected: Bool = true) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE wallets(id TEXT PRIMARY KEY, profileID TEXT, name TEXT, kind TEXT,
                    secretKeyReference TEXT, isSelected BOOLEAN, sortOrder INTEGER, createdAt DOUBLE, archivedAt DOUBLE);
                CREATE TABLE walletAccounts(id TEXT PRIMARY KEY, walletID TEXT, networkID TEXT, address TEXT,
                    normalizedAddress TEXT, label TEXT, derivationPath TEXT, accountIndex INTEGER, publicKey TEXT,
                    isWatchOnly BOOLEAN, isEnabled BOOLEAN);
                CREATE TABLE userSettings(profileID TEXT PRIMARY KEY, appLockEnabled BOOLEAN, biometricEnabled BOOLEAN,
                    autoLockSeconds INTEGER, privacyShieldEnabled BOOLEAN, languageIdentifier TEXT, currencyCode TEXT);
                CREATE TABLE profileSecurity(profileID TEXT PRIMARY KEY, passcodeKeychainReference TEXT,
                    failedAttemptCount INTEGER, lockedUntil DOUBLE);
                CREATE TABLE cachedBalances(value TEXT);
                INSERT INTO cachedBalances VALUES ('DISPOSABLE-NOT-MIGRATED');
                INSERT INTO userSettings VALUES ('local-default',?,0,300,1,'ar','USD');
                INSERT INTO profileSecurity VALUES ('local-default','opaque-test-reference',3,NULL);
                """, arguments: [protected])
            for i in 0..<12 {
                let id = String(format: "00000000-0000-0000-0000-%012d", i)
                try db.execute(sql: "INSERT INTO wallets VALUES (?,'local-default',?,'created',?,?,?,1,NULL)",
                               arguments: [id, "Synthetic \(i)", "reference-\(i)", i == 7, i])
                try db.execute(sql: "INSERT INTO walletAccounts VALUES (?,?,'eth',?,'test',NULL,?,0,NULL,0,1)",
                               arguments: [id + ":eth", id, "synthetic-public-\(i)", "m/44'/60'/0'/0/0"])
            }
        }
        return queue
    }
    private func destination() async throws -> OathDatabase {
        let db = try await OathDatabase.open(at: location())
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
            derivationPath: "m/44'/60'/0'/0/0", logo: "eth", sortOrder: 0)], assets: [])
        return db
    }
    private func batch() -> LegacyUpgradeBatch {
        let wallets = (0..<12).map { i -> WalletRecord in
            var w = WalletRecord(id: "test-\(i)", name: "Synthetic \(i)", kind: "hd", vaultReference: "vault-\(i)", createdAt: 1)
            w.sortOrder = i; w.nameGroup = "main"; w.nameIndex = i; return w
        }
        return .init(sourceFingerprint: String(repeating: "a", count: 64), wallets: wallets, accounts: wallets.map {
            .init(id: $0.id + ":eth", walletID: $0.id, networkID: "ethereum", address: "synthetic-" + $0.id, derivationPath: "m/44'/60'/0'/0/0")
        }, activeWalletID: "test-7", settings: ["security.appSwitcherPrivacy": "true"])
    }
    func testAbsentFileIsCleanInstallButCorruptionIsNot() async throws {
        let path = try location()
        let absent = try await LegacyWalletSource.read(at: path)
        XCTAssertNil(absent)
        try Data("invalid-sqlite".utf8).write(to: path)
        do { _ = try await LegacyWalletSource.read(at: path); XCTFail("Corruption must not become onboarding") }
        catch { }
    }
    func testReadsAllIdentitiesSecurityAndSelectionWithoutDisposableData() async throws {
        let path = try location(), queue = try oldDatabase(at: path)
        let input = try XCTUnwrap(LegacyWalletSource.readSynchronously(at: path))
        XCTAssertEqual(input.wallets.count, 12); XCTAssertEqual(input.accounts.count, 12)
        XCTAssertEqual(input.activeWalletID, input.wallets[7].id)
        XCTAssertTrue(input.security.appLockEnabled); XCTAssertEqual(input.security.failedAttempts, 3)
        XCTAssertEqual(input.security.autoLockSeconds, 300); XCTAssertTrue(input.security.privacyShieldEnabled)
        XCTAssertFalse(String(data: try JSONEncoder().encode(input), encoding: .utf8)!.contains("DISPOSABLE"))
        let stored = try await queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM cachedBalances") }
        XCTAssertEqual(stored, 1, "Reading cannot delete the original data")
    }
    func testMissingCredentialOrSelectionFailsClosed() throws {
        let path = try location(), queue = try oldDatabase(at: path)
        try queue.write { try $0.execute(sql: "DELETE FROM profileSecurity") }
        XCTAssertThrowsError(try LegacyWalletSource.readSynchronously(at: path)) { XCTAssertEqual($0 as? LegacyUpgradeError, .missingProtection) }
        try queue.write { try $0.execute(sql: "UPDATE wallets SET isSelected=0") }
        XCTAssertThrowsError(try LegacyWalletSource.readSynchronously(at: path)) { XCTAssertEqual($0 as? LegacyUpgradeError, .ambiguousSelection) }
    }
    func testAtomicCommitRetryPreservesLaterNameAndActiveSelection() async throws {
        let db = try await destination(), batch = batch()
        try await db.commitLegacyUpgrade(batch)
        var wallets = try await db.wallets()
        XCTAssertEqual(wallets.count, 12)
        var settings = try await db.settings(); XCTAssertEqual(settings["activeWalletID"], "test-7")
        try await db.renameWallet("test-0", name: "User changed this after migration")
        try await db.setSetting("activeWalletID", value: "test-2")
        try await db.commitLegacyUpgrade(batch)
        wallets = try await db.wallets(); settings = try await db.settings()
        XCTAssertEqual(wallets.count, 12); XCTAssertEqual(wallets[0].name, "User changed this after migration")
        XCTAssertEqual(settings["activeWalletID"], "test-2")
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM balances") }
        XCTAssertEqual(count, 0)
    }
    func testFailureRollsBackEveryWalletAndReceiptThenRetrySucceeds() async throws {
        let db = try await destination(), original = batch()
        var accounts = original.accounts
        accounts[11].networkID = "unknown-network"
        let bad = LegacyUpgradeBatch(sourceFingerprint: original.sourceFingerprint, wallets: original.wallets,
            accounts: accounts, activeWalletID: original.activeWalletID, settings: original.settings)
        do { try await db.commitLegacyUpgrade(bad); XCTFail("Foreign key failure must abort") } catch { }
        let empty = try await db.wallets(), settings = try await db.settings()
        XCTAssertTrue(empty.isEmpty); XCTAssertNil(settings["migration.legacyV1"])
        try await db.commitLegacyUpgrade(original)
        let committed = try await db.wallets(); XCTAssertEqual(committed.count, 12)
    }
    func testExistingDestinationIsNeverOverwritten() async throws {
        let db = try await destination(), batch = batch()
        try await db.importWalletIfNeeded(batch.wallets[0], accounts: [batch.accounts[0]])
        do { try await db.commitLegacyUpgrade(batch); XCTFail("Must preserve valid destination") }
        catch { XCTAssertEqual(error as? LegacyUpgradeError, .destinationOccupied) }
        let wallets = try await db.wallets(); XCTAssertEqual(wallets.count, 1)
    }

    func testAuthenticatedReplacementClearsTestLedgerSettingsAndPendingReset() async throws {
        let db = try await destination()
        let old = batch()
        try await db.commitLegacyUpgrade(old)
        try await db.setSetting("test.preference", value: "obsolete")
        _ = try await db.beginWalletReset()
        var replacement = batch()
        replacement.replacementID = UUID()
        try await db.commitLegacyUpgrade(replacement)
        let settings = try await db.settings()
        XCTAssertNil(settings["test.preference"])
        XCTAssertEqual(settings["activeWalletID"], replacement.activeWalletID)
        XCTAssertEqual(settings["migration.legacyReplacementV2"], replacement.replacementID?.uuidString)
        let reset = try await db.pendingWalletReset(); XCTAssertNil(reset)
        for table in OathDatabase.walletDataTables where table != "wallets" && table != "accounts" {
            let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(table)") }
            XCTAssertEqual(count, 0, table)
        }
        try await db.renameWallet("test-0", name: "After replacement")
        try await db.setSetting("activeWalletID", value: "test-1")
        try await db.commitLegacyUpgrade(replacement)
        let repeated = try await db.wallets(), repeatedSettings = try await db.settings()
        XCTAssertEqual(repeated.first?.name, "After replacement")
        XCTAssertEqual(repeatedSettings["activeWalletID"], "test-1")
    }

    func testReplacementFailureRollsBackErasureAndOldReceipts() async throws {
        let db = try await destination(), original = batch()
        try await db.commitLegacyUpgrade(original)
        try await db.renameWallet("test-0", name: "Keep until verified")
        try await db.setSetting("test.preference", value: "preserve on failure")
        let before = try await db.wallets(), beforeSettings = try await db.settings()
        let reset = try await db.beginWalletReset()
        var accounts = original.accounts
        accounts[11].networkID = "invalid-network"
        var invalid = LegacyUpgradeBatch(sourceFingerprint: String(repeating: "b", count: 64),
            wallets: original.wallets, accounts: accounts, activeWalletID: original.activeWalletID, settings: original.settings)
        invalid.replacementID = UUID()
        do { try await db.commitLegacyUpgrade(invalid); XCTFail("Invalid account must roll back replacement") }
        catch { }
        let after = try await db.wallets(), afterSettings = try await db.settings(), pending = try await db.pendingWalletReset()
        XCTAssertEqual(after, before); XCTAssertEqual(afterSettings, beforeSettings); XCTAssertEqual(pending, reset)
    }

    func testChangedLegacySecurityChangesFingerprintWithoutChangingWallets() throws {
        let path = try location(), queue = try oldDatabase(at: path)
        let before = try XCTUnwrap(LegacyWalletSource.readSynchronously(at: path))
        try queue.write { try $0.execute(sql: "UPDATE profileSecurity SET failedAttemptCount=4") }
        let after = try XCTUnwrap(LegacyWalletSource.readSynchronously(at: path))
        XCTAssertNotEqual(try before.fingerprint, try after.fingerprint)
        XCTAssertEqual(before.wallets, after.wallets)
        XCTAssertEqual(before.accounts, after.accounts)
    }

    func testStaleReceiptRecoversVerifiedWalletsWithoutRollingBackUserEdits() async throws {
        let db = try await destination(), original = batch()
        try await db.commitLegacyUpgrade(original)
        try await db.renameWallet("test-0", name: "Renamed after upgrade")
        try await db.setSetting("activeWalletID", value: "test-2")
        try await db.setSetting("security.appSwitcherPrivacy", value: "false")
        try await db.pool.write { try $0.execute(sql: "UPDATE accounts SET syncGeneration=42") }
        let beforeWallets = try await db.wallets()
        let beforeAccounts = try await db.accounts(walletID: "test-0")
        let pending = LegacyUpgradeBatch(sourceFingerprint: String(repeating: "b", count: 64),
            wallets: original.wallets, accounts: original.accounts, activeWalletID: original.activeWalletID,
            settings: original.settings)
        for _ in 0..<3 { try await db.commitLegacyUpgrade(pending) }
        let afterWallets = try await db.wallets(), afterAccounts = try await db.accounts(walletID: "test-0")
        let settings = try await db.settings()
        XCTAssertEqual(afterWallets, beforeWallets); XCTAssertEqual(afterAccounts, beforeAccounts)
        XCTAssertEqual(settings["migration.legacyV1"], pending.sourceFingerprint)
        XCTAssertEqual(settings["activeWalletID"], "test-2")
        XCTAssertEqual(settings["security.appSwitcherPrivacy"], "false")
    }

    func testStaleReceiptNeverAcceptsDifferentOrMissingWalletIdentity() async throws {
        for field in ["vaultReference", "kind", "createdAt", "deletedAt", "missingWallet",
                      "walletID", "networkID", "address", "derivationPath", "accountIndex", "missingAccount"] {
            let db = try await destination(), original = batch()
            try await db.commitLegacyUpgrade(original)
            var wallets = original.wallets, accounts = original.accounts
            switch field {
            case "vaultReference": wallets[0].vaultReference = "another-vault"
            case "kind": wallets[0].kind = "privateKey"
            case "createdAt": wallets[0].createdAt = 2
            case "deletedAt": try await db.pool.write { try $0.execute(sql: "UPDATE wallets SET deletedAt=2 WHERE id='test-0'") }
            case "missingWallet": try await db.deleteWalletMetadata("test-0")
            case "walletID": accounts[0].walletID = wallets[1].id
            case "networkID": accounts[0].networkID = "another-network"
            case "address": accounts[0].address = "another-public-address"
            case "derivationPath": accounts[0].derivationPath = "m/44'/60'/0'/0/1"
            case "accountIndex": accounts[0].accountIndex = 1
            default: try await db.pool.write { try $0.execute(sql: "DELETE FROM accounts WHERE id='test-0:eth'") }
            }
            let before = try await db.wallets(includingDeleted: true)
            let pending = LegacyUpgradeBatch(sourceFingerprint: String(repeating: "b", count: 64),
                wallets: wallets, accounts: accounts, activeWalletID: original.activeWalletID, settings: original.settings)
            do { try await db.commitLegacyUpgrade(pending); XCTFail("Accepted incompatible identity: \(field)") }
            catch { XCTAssertEqual(error as? LegacyUpgradeError, .conflictingReceipt, field) }
            let after = try await db.wallets(includingDeleted: true), settings = try await db.settings()
            XCTAssertEqual(after, before, field)
            XCTAssertEqual(settings["migration.legacyV1"], original.sourceFingerprint, field)
        }
    }

    func testReceiptRecoveryDiagnosticsContainNoWalletData() async throws {
        let transport = LegacyDiagnosticProbe()
        OathDiagnostics.configure(file: try location().deletingLastPathComponent().appendingPathComponent("diagnostics.json"),
                                  transport: transport)
        let db = try await destination(), original = batch(), operationID = UUID()
        try await db.commitLegacyUpgrade(original)
        let pending = LegacyUpgradeBatch(sourceFingerprint: String(repeating: "b", count: 64),
            wallets: original.wallets, accounts: original.accounts, activeWalletID: original.activeWalletID,
            settings: original.settings)
        try await OathDiagnostics.$operationID.withValue(operationID) { try await db.commitLegacyUpgrade(pending) }
        var reports: [DiagnosticEvent] = []
        for _ in 0..<100 {
            reports = await transport.events().filter { $0.operationID == operationID }
            if !reports.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let report = try XCTUnwrap(reports.first)
        XCTAssertEqual(report.component, "legacy_upgrade")
        XCTAssertEqual(report.operation, "verify_receipt")
        XCTAssertEqual(report.context, ["stage": "verify_committed_records"])
        let wire = String(decoding: try JSONEncoder().encode(report), as: UTF8.self)
        for value in [original.sourceFingerprint, pending.sourceFingerprint] + original.wallets.flatMap({ [$0.id, $0.name, $0.vaultReference] }) + original.accounts.map(\.address) {
            XCTAssertFalse(wire.contains(value))
        }
    }
}

private actor LegacyDiagnosticProbe: DiagnosticTransport {
    private var received: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { received += events }
    func events() -> [DiagnosticEvent] { received }
}
