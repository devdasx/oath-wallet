import Foundation
import CryptoKit
import OathDatabase
import OathDiagnostics
import SQLite3

private actor LegacyReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

/// Host regression checks use the production migration loop, BIP-39 validator,
/// envelope, vault, session and database. The iOS-only derivation/ownership
/// adapter uses synthetic public addresses (see CheckMultiWallet.py).
@main struct CheckLegacyUpgrade {
    static let pin: [UInt8] = [1, 2, 8, 4, 7, 3]
    // Public BIP-39 test vector, never a user credential.
    static let phrase = Array(repeating: "abandon", count: 11).joined(separator: " ") + " about"

    final class Secrets: OathLegacySecretReading, @unchecked Sendable {
        let values: [String: Data]
        let failure: LegacyUpgradeError?
        let cancel: Bool
        private let lock = NSLock()
        private var readCount = 0
        var reads: Int { lock.withLock { readCount } }
        init(_ values: [String: Data], failure: LegacyUpgradeError? = nil, cancel: Bool = false) {
            self.values = values; self.failure = failure; self.cancel = cancel
        }
        func read(reference: String) throws -> Data {
            lock.withLock { readCount += 1 }
            if cancel { throw CancellationError() }
            if let failure { throw failure }
            guard let value = values[reference] else { throw LegacyUpgradeError.keyUnavailable }
            return value
        }
    }

    final class Storage: OathVaultStorage, @unchecked Sendable {
        let memory = WalletMemory()
        private let lock = NSLock()
        private var failCompletion = false
        func interruptCompletion() { lock.withLock { failCompletion = true } }
        func read(_ account: String) throws -> Data? { try memory.read(account) }
        func insert(_ data: Data, account: String) throws { try memory.insert(data, account: account) }
        func update(_ data: Data, account: String) throws {
            if lock.withLock({
                if account == "legacy-upgrade-complete-v2", !data.isEmpty, failCompletion {
                    failCompletion = false; return true
                }
                return false
            }) { throw LegacyUpgradeError.interrupted }
            try memory.update(data, account: account)
        }
        func erase() throws { try memory.erase() }
    }

    static func fixture(skipped: Set<Int>, count: Int = 3, selected: Int = 0,
                        protected: Bool = false, envelope: Bool = false) throws -> (LegacyWalletSnapshot, Secrets) {
        var wallets: [[String: Any]] = [], accounts: [[String: Any]] = [], values: [String: Data] = [:]
        for index in 0..<count {
            let id = String(format: "00000000-0000-0000-0000-%012d", index + 1)
            let reference = "synthetic-recovery-\(index)"
            wallets.append(["id": id, "name": "Fixture \(index)", "kind": "importedRecoveryPhrase",
                "secretKeyReference": reference, "isSelected": index == selected, "sortOrder": index,
                "createdAt": 1.0])
            accounts.append(["id": id + ":eth", "walletID": id, "networkID": "eth",
                "address": "synthetic-address-" + id + "ethereum", "normalizedAddress": "fixture",
                "derivationPath": "m/44'/60'/0'/0/0", "isWatchOnly": false, "isEnabled": true])
            if envelope {
                values[reference] = try JSONSerialization.data(withJSONObject: [
                    "format": "aperture.wallet.recovery-credential", "version": 2,
                    "mnemonic": phrase, "passphrase": "", "scheme": skipped.contains(index) ? "electrum" : "bip39"
                ])
            } else {
                values[reference] = Data((skipped.contains(index) ? "unsupported synthetic recovery format" : phrase).utf8)
            }
        }
        let verifier = try OathPasscodeRecord.make(digits: pin, salt: Array(repeating: 1, count: 32), iterations: 210_000)
        values["synthetic-verifier"] = try JSONSerialization.data(withJSONObject: [
            "algorithm": "pbkdf2-hmac-sha256", "iterations": 210_000,
            "salt": verifier.salt.base64EncodedString(), "verifier": verifier.verifier.base64EncodedString()
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "wallets": wallets, "accounts": accounts,
            "security": ["appLockEnabled": protected, "biometricEnabled": false,
                "passcodeReference": "synthetic-verifier", "failedAttempts": 0,
                "autoLockSeconds": 60, "privacyShieldEnabled": true, "language": "en", "currency": "USD"]
        ])
        return (try JSONDecoder().decode(LegacyWalletSnapshot.self, from: data), Secrets(values))
    }

    actor RecoveryEnvironment: OathResetEnvironment {
        let legacyURL: URL
        var fail = false
        private(set) var preferencesErased = 0
        init(legacyURL: URL) { self.legacyURL = legacyURL }
        func failNextErase() { fail = true }
        func suspend() async { }
        func reopen() async { }
        func eraseLocalFiles() async throws {
            if fail { fail = false; throw LegacyUpgradeError.interrupted }
            try OathResetFileCleanup.remove([legacyURL])
        }
        func eraseRecoveryPreferences() async throws { preferencesErased += 1 }
        func eraseEmptyWalletFiles() async throws {
            if fail { fail = false; throw LegacyUpgradeError.interrupted }
            // The automatic empty-destination reset keeps the old source.
        }
    }

    static func writeLegacySource(_ source: LegacyWalletSnapshot, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw LegacyUpgradeError.invalidSource }
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw LegacyUpgradeError.invalidSource }
        }
        func q(_ text: String?) -> String { text.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        try execute("""
            CREATE TABLE wallets(id TEXT, name TEXT, kind TEXT, secretKeyReference TEXT, isSelected INT, sortOrder INT, createdAt DOUBLE, profileID TEXT, archivedAt DOUBLE);
            CREATE TABLE walletAccounts(id TEXT, walletID TEXT, networkID TEXT, address TEXT, normalizedAddress TEXT, label TEXT, derivationPath TEXT, accountIndex INT, publicKey TEXT, isWatchOnly INT, isEnabled INT);
            CREATE TABLE userSettings(profileID TEXT, appLockEnabled INT, biometricEnabled INT, autoLockSeconds INT, privacyShieldEnabled INT, languageIdentifier TEXT, currencyCode TEXT);
            CREATE TABLE profileSecurity(profileID TEXT, passcodeKeychainReference TEXT, failedAttemptCount INT, lockedUntil DOUBLE);
            INSERT INTO userSettings VALUES('local-default',\(source.security.appLockEnabled ? 1 : 0),0,60,1,'en','USD');
            INSERT INTO profileSecurity VALUES('local-default',\(q(source.security.passcodeReference)),0,NULL);
            """)
        for w in source.wallets {
            try execute("INSERT INTO wallets VALUES(\(q(w.id)),\(q(w.name)),\(q(w.kind)),\(q(w.secretKeyReference)),\(w.isSelected ? 1 : 0),\(w.sortOrder),\(w.createdAt),'local-default',NULL)")
        }
        for a in source.accounts {
            try execute("INSERT INTO walletAccounts VALUES(\(q(a.id)),\(q(a.walletID)),\(q(a.networkID)),\(q(a.address)),\(q(a.normalizedAddress)),NULL,\(q(a.derivationPath)),0,NULL,\(a.isWatchOnly ? 1 : 0),\(a.isEnabled ? 1 : 0))")
        }
    }

    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathLegacySkip-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = LegacyReports()
        OathDiagnostics.configure(file: directory.appendingPathComponent("diagnostics.json"), transport: reports)
        // The production migration's fixed failure category must survive the
        // shared allowlist. Never record the failed wallet or credential data.
        let missingOperation = UUID()
        let (missingSource, _) = try fixture(skipped: [])
        let (_, missingResult) = try OathDiagnostics.$operationID.withValue(missingOperation) {
            try OathLegacyUpgrade.prepare(missingSource, secrets: Secrets([:]))
        }
        check(missingResult.wallets.isEmpty && missingResult.skippedUnsupportedWalletCount == 3,
              "Missing credentials remain skipped, with no replacement wallet")
        var missingReports: [DiagnosticEvent] = []
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            missingReports = await reports.events.filter { $0.operationID == missingOperation }
            if !missingReports.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(missingReports.count == 1, "Repeated same-cause skips produce one correlated report")
        check(missingReports[0].context["reason"] == "key_unavailable",
              "The safe legacy cause must survive the context allowlist")
        let missingWire = String(decoding: try JSONEncoder().encode(missingReports), as: UTF8.self)
        check(missingSource.wallets.flatMap { [$0.id, $0.name, $0.secretKeyReference!] }
            .allSatisfy { !missingWire.contains($0) }, "Legacy failure context excludes wallet and credential identifiers")
        func database() async throws -> OathDatabase {
            let db = try await OathDatabase.open(at: directory.appendingPathComponent(UUID().uuidString + ".sqlite"))
            try await OathDataEnvironment.seed(db)
            return db
        }
        // Root skipped, active skipped, unsupported last, mixed and all skipped;
        // both plain phrases and explicit non-BIP39 credential envelopes.
        for envelope in [false, true] {
            for skipped: Set<Int> in [[], [0], [1], [2], [0, 1], [0, 1, 2]] {
                let (source, secrets) = try fixture(skipped: skipped, selected: 1, envelope: envelope)
                let (contents, batch) = try OathLegacyUpgrade.prepare(source, secrets: secrets)
                let supported = source.wallets.enumerated().filter { !skipped.contains($0.offset) }.map(\.element.id)
                check(batch.wallets.map(\.id) == supported, "Only supported recovery wallets are imported in original order")
                check(batch.activeWalletID == (supported.contains(source.activeWalletID!) ? source.activeWalletID : supported.first),
                      "Selection must fall back only if the selected wallet was skipped")
                check(batch.skippedRecoveryWalletCount == skipped.count, "Skipped count must be explicit")
                check(Set(batch.accounts.map(\.walletID)) == Set(supported), "Skipped wallets have no destination accounts")
                try contents.validate(rootID: UUID(uuidString: source.wallets[0].id)!)
                let storage = Storage(), db = try await database(), biometrics = MemoryBiometrics()
                let vault = OathWalletVault(storage: storage, biometricStore: biometrics,
                    database: db, resetEnvironment: LifecycleResetEnvironment())
                let result = try await vault.migrateLegacy(source, digits: nil, secrets: secrets, verifySource: false)
                check(try await vault.wallets().map(\.id) == supported, "Committed membership matches preparation")
                check(result.id.uuidString == (batch.activeWalletID ?? source.wallets[0].id),
                      "Root stays a credential anchor when its wallet was skipped")
                check(try await !vault.needsLegacyMigration(source), "Completed skip must not repeat at the next launch")
                check(source.wallets.count == 3 && secrets.values.count == 4, "Original metadata and credentials remain intact")
                let reads = secrets.reads
                _ = try await vault.migrateLegacy(source, digits: nil, secrets: secrets, verifySource: false)
                check(secrets.reads == reads, "A completed migration never rereads skipped recovery material")
                await vault.lock()
                let reopened = OathWalletVault(storage: storage, biometricStore: biometrics,
                    database: db, resetEnvironment: LifecycleResetEnvironment())
                _ = try await reopened.unlockWithoutPasscode()
                check(try await reopened.wallets().map(\.id) == supported, "Cold unlock preserves the imported subset")
                let session = OathWalletSession(vault: reopened, legacySourceURL: directory.appendingPathComponent("absent.sqlite"))
                await session.finishedSetup(requiresCustomization: false)
                check(session.wallets.map(\.id) == supported, "Session contains only imported wallets")
                check(supported.isEmpty ? session.presentsOnboarding && !session.isUnlocked : session.isUnlocked,
                      "All-skipped migrations reach Welcome; valid siblings reach Home")
                await session.lock()
            }
        }

        let (empty, emptySecrets) = try fixture(skipped: [0], count: 1, protected: true)
        let storage = Storage(), db = try await database(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics,
            database: db, resetEnvironment: LifecycleResetEnvironment())
        do {
            _ = try await vault.migrateLegacy(empty, digits: [0,0,0,0,0,0], secrets: emptySecrets, verifySource: false)
            preconditionFailure("Skipped wallets must not bypass old authentication")
        } catch OathWalletError.wrongPasscode { checks += 1 }
        check(emptySecrets.reads == 1, "Wrong PIN reads the verifier only")
        check(try storage.read("vault-v1") == nil, "Wrong PIN never commits an empty migration")
        storage.interruptCompletion()
        do {
            _ = try await vault.migrateLegacy(empty, digits: pin, secrets: emptySecrets, verifySource: false)
            preconditionFailure("Injected completion failure must surface")
        } catch LegacyUpgradeError.interrupted { checks += 1 }
        check(try await vault.needsLegacyMigration(empty), "Interrupted completion still requires authenticated migration")
        let retry = OathWalletVault(storage: storage, biometricStore: biometrics,
            database: db, resetEnvironment: LifecycleResetEnvironment())
        _ = try await retry.migrateLegacy(empty, digits: pin, secrets: emptySecrets, verifySource: false)
        check(try await !retry.needsLegacyMigration(empty), "Retry completes an all-skipped migration")
        check(try await retry.wallets().isEmpty, "Retry never manufactures a wallet")
        await retry.lock()
        do { _ = try await retry.unlockWithoutPasscode(); preconditionFailure("Protection must survive empty migration") }
        catch { checks += 1 }
        _ = try await retry.unlock(digits: pin)
        check(try await retry.securityState().passcodeEnabled, "Original PIN protects the empty collection")
        let session = OathWalletSession(vault: retry, legacySourceURL: directory.appendingPathComponent("absent.sqlite"))
        await session.finishedSetup(requiresCustomization: false)
        check(session.presentsOnboarding && !session.isUnlocked && session.security == OathWalletSecurityState(),
              "Authenticated empty upgrade resets stale protection and opens Welcome")
        check(try await !retry.exists(), "Welcome can configure a fresh vault")
        try await OathDataEnvironment.seed(db) // Live reset environment reseeds the catalog.
        try await retry.create(digits: pin, importing: nil)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && session.wallets.count == 1, "Welcome creates the first wallet after all old mnemonics were skipped")
        check(try await !retry.needsLegacyMigration(empty), "Adding a wallet never reimports the skipped originals")
        await session.lock()

        // Malformed, missing and mismatched wallet data is isolated to that
        // wallet; user cancellation still aborts the operation.
        let (source, original) = try fixture(skipped: [0])
        for data in [Data([0xff]), Data("{broken".utf8)] {
            var values = original.values
            values["synthetic-recovery-1"] = data
            let (contents, batch) = try OathLegacyUpgrade.prepare(source, secrets: Secrets(values))
            check(contents.wallets.map { $0.id.uuidString } == [source.wallets[2].id], "Damaged sibling does not block valid wallet")
            check(batch.skippedUnsupportedWalletCount == 1, "Damaged wallet is recorded as skipped")
        }
        let (_, missingBatch) = try OathLegacyUpgrade.prepare(source, secrets: Secrets([:]))
        check(missingBatch.wallets.isEmpty && missingBatch.skippedUnsupportedWalletCount == 3, "Missing keys yield an empty protected collection")
        do { _ = try OathLegacyUpgrade.prepare(source, secrets: Secrets(original.values, cancel: true)); preconditionFailure("Cancellation ignored") }
        catch is CancellationError { checks += 1 }
        for problem in ["ownership", "network", "watchOnly", "hardware", "reference", "noAccounts", "identifier", "name"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
            var accounts = object["accounts"] as! [[String: Any]]
            var wallets = object["wallets"] as! [[String: Any]]
            switch problem {
            case "ownership": accounts[1]["address"] = "synthetic-unrelated-address"
            case "network": accounts[1]["networkID"] = "retired-fixture-chain"
            case "watchOnly": wallets[1]["kind"] = "watchOnly"; wallets[1].removeValue(forKey: "secretKeyReference")
            case "hardware": wallets[1]["kind"] = "hardware"
            case "reference": wallets[1].removeValue(forKey: "secretKeyReference")
            case "noAccounts": accounts.remove(at: 1)
            case "identifier": wallets[1]["id"] = "invalid-fixture-id"
            default: wallets[1]["name"] = ""
            }
            object["accounts"] = accounts; object["wallets"] = wallets
            let partial = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            let (_, batch) = try OathLegacyUpgrade.prepare(partial, secrets: original)
            check(batch.wallets.map(\.id) == [source.wallets[2].id], "Invalid sibling skipped: " + problem)
            check(batch.activeWalletID == source.wallets[2].id, "Selection falls back to a valid imported wallet")
            let partialDB = try await database(), partialStorage = Storage()
            let partialVault = OathWalletVault(storage: partialStorage, biometricStore: MemoryBiometrics(),
                database: partialDB, resetEnvironment: LifecycleResetEnvironment())
            _ = try await partialVault.migrateLegacy(partial, digits: nil, secrets: original, verifySource: false)
            check(try await partialVault.wallets().map(\.id) == [source.wallets[2].id], "Valid sibling actually commits")
        }

        for allMissing in [false, true] {
            let (input, credentials) = try fixture(skipped: [], selected: 1, protected: true)
            var values = credentials.values
            values.removeValue(forKey: "synthetic-recovery-1")
            if allMissing {
                values.removeValue(forKey: "synthetic-recovery-0")
                values.removeValue(forKey: "synthetic-recovery-2")
            }
            let url = directory.appendingPathComponent(UUID().uuidString + "-source.sqlite")
            try writeLegacySource(input, at: url)
            let target = try await database(), memory = Storage()
            let localVault = OathWalletVault(storage: memory, biometricStore: MemoryBiometrics(),
                database: target, resetEnvironment: LifecycleResetEnvironment())
            let localSession = OathWalletSession(vault: localVault, legacySourceURL: url, legacySecrets: Secrets(values))
            await localSession.load()
            await localSession.upgradeLegacy(digits: pin)
            check((allMissing ? localSession.presentsOnboarding && !localSession.isUnlocked : localSession.isUnlocked)
                  && localSession.notice == nil, "Missing wallet data reaches Welcome or a valid Home without an error")
            check(localSession.wallets.count == (allMissing ? 0 : 2), "Only valid wallets appear on Home")
            check(localSession.displayedProfile?.id.uuidString == (allMissing ? nil : input.wallets[0].id), "Welcome has no wallet; Home selects a valid wallet")
            check(FileManager.default.fileExists(atPath: url.path), "Ordinary skipping never erases originals")
            if allMissing {
                let coldVault = OathWalletVault(storage: memory, biometricStore: MemoryBiometrics(),
                    database: target, resetEnvironment: LifecycleResetEnvironment())
                let cold = OathWalletSession(vault: coldVault, legacySourceURL: url, legacySecrets: Secrets([:]))
                await cold.load()
                check(cold.presentsOnboarding && !cold.isUpgrading && !cold.isUnlocked,
                      "Cold launch stays on Welcome even while skipped originals remain")
            }
            await localSession.resetFailedLegacyUpgrade()
            check(try await target.pendingWalletReset() == nil, "Recovery reset cannot be used from Home")
            await localSession.lock()
        }

        var invalidObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        var invalidWallets = invalidObject["wallets"] as! [[String: Any]]
        for index in invalidWallets.indices { invalidWallets[index]["id"] = "invalid-identifier-" + String(index) }
        invalidObject["wallets"] = invalidWallets
        let invalidSource = try JSONDecoder().decode(LegacyWalletSnapshot.self, from: JSONSerialization.data(withJSONObject: invalidObject))
        let invalidDB = try await database(), invalidStorage = Storage()
        let invalidVault = OathWalletVault(storage: invalidStorage, biometricStore: MemoryBiometrics(),
            database: invalidDB, resetEnvironment: LifecycleResetEnvironment())
        _ = try await invalidVault.migrateLegacy(invalidSource, digits: nil, secrets: original, verifySource: false)
        check(try await invalidVault.wallets().isEmpty, "All invalid IDs still commit an empty collection")
        check(try await !invalidVault.needsLegacyMigration(invalidSource), "Stable fallback root completes the migration")

        // Automatic cleanup is authorized by decrypted membership, never by an
        // empty public table or an unloaded session. It is resumable at every step.
        let validDB = try await database(), validStorage = Storage()
        let validVault = OathWalletVault(storage: validStorage, biometricStore: MemoryBiometrics(),
            database: validDB, resetEnvironment: LifecycleResetEnvironment())
        try await validVault.create(digits: pin, importing: nil)
        let validID = try await validVault.unlockedProfile().id.uuidString
        try await validDB.deleteWalletMetadata(validID)
        check(try await !validVault.beginEmptyWalletResetIfNeeded(), "Missing public metadata never resets a valid encrypted wallet")
        await validVault.lock()
        do { _ = try await validVault.beginEmptyWalletResetIfNeeded(); preconditionFailure("Locked membership cannot authorize empty reset") }
        catch OathWalletError.locked { checks += 1 }
        _ = try await validVault.unlock(digits: pin)
        check(try await validVault.wallets().map(\.id) == [validID], "Unlock repairs missing wallet metadata")

        let interruptedURL = directory.appendingPathComponent("empty-resume-source.sqlite")
        try writeLegacySource(empty, at: interruptedURL)
        guard let interruptedSource = try await LegacyWalletSource.read(at: interruptedURL) else {
            preconditionFailure("The persisted legacy fixture must be readable")
        }
        let interruptedDB = try await database(), interruptedStorage = Storage()
        let interruptedEnvironment = RecoveryEnvironment(legacyURL: interruptedURL)
        let interruptedVault = OathWalletVault(storage: interruptedStorage, biometricStore: MemoryBiometrics(),
            database: interruptedDB, resetEnvironment: interruptedEnvironment)
        _ = try await interruptedVault.migrateLegacy(interruptedSource, digits: pin, secrets: emptySecrets, sourceURL: interruptedURL)
        check(try await interruptedVault.beginEmptyWalletResetIfNeeded(), "Authenticated empty vault grants only cleanup")
        await interruptedEnvironment.failNextErase()
        do { _ = try await interruptedVault.resumeResetIfNeeded(); preconditionFailure("Injected empty cleanup failure must persist") }
        catch LegacyUpgradeError.interrupted { checks += 1 }
        check(try await interruptedDB.pendingEmptyWalletReset() != nil, "Interrupted cleanup retains its source receipt and policy")
        check(FileManager.default.fileExists(atPath: interruptedURL.path), "Automatic cleanup preserves skipped recovery source")
        // The pending journal wins before reading even a temporarily unreadable old source.
        let originalBytes = try Data(contentsOf: interruptedURL)
        try Data("unreadable synthetic source".utf8).write(to: interruptedURL)
        let resumedVault = OathWalletVault(storage: interruptedStorage, biometricStore: MemoryBiometrics(),
            database: interruptedDB, resetEnvironment: interruptedEnvironment)
        let resumed = OathWalletSession(vault: resumedVault, legacySourceURL: interruptedURL, legacySecrets: Secrets([:]))
        await resumed.load()
        for _ in 0..<500 {
            if resumed.presentsOnboarding || resumed.resetFailed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(resumed.presentsOnboarding && !resumed.resetting, "Restart resumes empty cleanup and opens Welcome without old authentication")
        check(try await interruptedDB.pendingEmptyWalletReset() == nil, "Successful empty cleanup clears its journal")
        try originalBytes.write(to: interruptedURL)
        let finalVault = OathWalletVault(storage: interruptedStorage, biometricStore: MemoryBiometrics(),
            database: interruptedDB, resetEnvironment: interruptedEnvironment)
        let final = OathWalletSession(vault: finalVault, legacySourceURL: interruptedURL, legacySecrets: Secrets([:]))
        await final.load()
        check(final.presentsOnboarding && !final.isLocked, "Retained completion receipt prevents repeating migration after restart")

        // Exercise the real session routing and durable reset with disposable
        // public SQLite fixtures, never the app's database or Keychain.
        let (protectedSource, _) = try fixture(skipped: [], count: 1, protected: true)
        let legacyURL = directory.appendingPathComponent("legacy.sqlite")
        try writeLegacySource(protectedSource, at: legacyURL)
        let resetDB = try await database(), resetStorage = Storage(), resetBiometrics = MemoryBiometrics()
        let resetEnvironment = RecoveryEnvironment(legacyURL: legacyURL)
        let resetVault = OathWalletVault(storage: resetStorage, biometricStore: resetBiometrics,
            database: resetDB, resetEnvironment: resetEnvironment)
        let resetSession = OathWalletSession(vault: resetVault, legacySourceURL: legacyURL, legacySecrets: Secrets([:]))
        await resetSession.load()
        check(resetSession.legacyPhase == .passcode, "Old authentication is preserved")
        await resetSession.resetFailedLegacyUpgrade()
        check(try await resetDB.pendingWalletReset() == nil, "Reset cannot bypass the ordinary passcode screen")
        // Missing old verifier is a genuine failure with no possible PIN path.
        await resetSession.upgradeLegacy(digits: pin)
        check(resetSession.isUpgrading && resetSession.legacyPhase == .failed, "Unrecoverable protection failure exposes recovery actions")
        resetSession.enteredBackground(delay: .immediately)
        check(resetSession.legacyPhase == .failed, "Backgrounding does not restart failed migration")
        try await resetDB.setSetting("currency", value: "EUR")
        await resetEnvironment.failNextErase()
        let biometricReads = await resetBiometrics.reads
        await resetSession.resetFailedLegacyUpgrade()
        check(resetSession.resetting && resetSession.resetFailed, "Partial erasure stays on resumable reset screen")
        check(try await resetDB.pendingLegacyRecoveryReset(), "Explicit recovery reset retains distinct durable intent")
        check(await resetBiometrics.reads == biometricReads, "Recovery reset never asks for biometrics or PIN")
        check(try await resetDB.settings().isEmpty, "Recovery reset removes app preferences too")
        // A corrupt old file must not outrank an already confirmed recovery reset.
        try Data("broken synthetic legacy database".utf8).write(to: legacyURL)
        let relaunchedVault = OathWalletVault(storage: resetStorage, biometricStore: resetBiometrics,
            database: resetDB, resetEnvironment: resetEnvironment)
        let relaunched = OathWalletSession(vault: relaunchedVault, legacySourceURL: legacyURL, legacySecrets: Secrets([:]))
        await relaunched.load()
        for _ in 0..<500 {
            if relaunched.presentsOnboarding || relaunched.resetFailed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(relaunched.presentsOnboarding && !relaunched.resetting, "Cold launch completes erasure before legacy reading")
        check(try await !resetDB.pendingLegacyRecoveryReset(), "Completed reset clears its recovery intent last")
        check(!FileManager.default.fileExists(atPath: legacyURL.path), "Reset deletes the disposable legacy source")
        check(await resetEnvironment.preferencesErased == 1, "Full local preference cleanup finishes once")
        do { try await relaunchedVault.beginFailedLegacyReset(source: protectedSource); preconditionFailure("Reset available without a failed upgrade") }
        catch { checks += 1 }
        checks += try await CheckMultiWallet.checkReset()
        let operationID = UUID()
        _ = try OathDiagnostics.$operationID.withValue(operationID) {
            try OathLegacyUpgrade.prepare(source, secrets: original)
        }
        var matching: [DiagnosticEvent] = []
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            matching = await reports.events.filter { $0.operationID == operationID }
            if !matching.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(matching.count == 1, "A skip attempt emits one correlated report")
        check(matching[0].operation == "skip_unsupported_recovery" && matching[0].context["stage"] == "prepare",
              "Skip diagnostics contain only fixed, safe context")
        let wire = String(decoding: try JSONEncoder().encode(matching), as: UTF8.self)
        let privateValues = [phrase, "unsupported synthetic recovery format", try source.fingerprint]
            + source.wallets.flatMap { [$0.id, $0.name, $0.secretKeyReference!] }
        check(privateValues.allSatisfy { !wire.contains($0) }, "Skipped wallet data never enters diagnostics")
        print("Passed \(checks) legacy migration host checks. No simulator, device, user Keychain or network used. WalletCore ownership/derivation is a synthetic adapter.")
    }
}
