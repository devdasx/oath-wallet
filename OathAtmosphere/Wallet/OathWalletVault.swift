import OathDiagnostics
import Foundation
import OathCloudBackup
import CryptoKit
import Security
import OathDatabase
import OathBitcoin
import OathAnkr

protocol OathVaultStorage: Sendable {
    func read(_ account: String) throws -> Data?
    func insert(_ data: Data, account: String) throws
    func update(_ data: Data, account: String) throws
    func erase() throws
    func replace(_ data: Data, account: String) throws
}

extension OathVaultStorage {
    func replace(_ data: Data, account: String) throws {
        if try read(account) == nil { try insert(data, account: account) }
        else { try update(data, account: account) }
    }
}

struct OathVaultKeychain: OathVaultStorage {
    let service: String
    init(service: String = (Bundle.main.bundleIdentifier ?? "org.oathwallet.atmosphere.studio") + ".wallet-vault") {
        self.service = service
    }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try OathKeychainPasscodeWriter.check(status)
        guard let data = result as? Data else { throw OathWalletError.corruptVault }
        return data
    }
    func insert(_ data: Data, account: String) throws {
        var query = query(account)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = data
        try OathKeychainPasscodeWriter.check(SecItemAdd(query as CFDictionary, nil))
    }
    func update(_ data: Data, account: String) throws {
        try OathKeychainPasscodeWriter.check(SecItemUpdate(query(account) as CFDictionary,
                                                          [kSecValueData as String: data] as CFDictionary))
    }
    func erase() throws {
        var query = query("")
        query.removeValue(forKey: kSecAttrAccount as String)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OathInstallationSecurityError.keychain(status)
        }
    }
}

struct OathUnlockAttempts: Codable, Sendable {
    var failures = 0
    var blockedUntil: Date?
    mutating func recordAttempt(now: Date) {
        failures = min(failures + 1, 20)
        if failures >= 5 {
            blockedUntil = now.addingTimeInterval(min(3_600, 30 * pow(2, Double(failures - 5))))
        }
    }
}

actor OathWalletVault: OathRecoveryPhraseReading, OathPrivateKeyReading {
    static let biometricService = (Bundle.main.bundleIdentifier ?? "org.oathwallet.atmosphere.studio") + ".wallet-biometry-v1"
    private let storage: any OathVaultStorage
    nonisolated let biometricStore: any OathBiometricCredentialStoring
    private var authenticationGeneration = UUID()
    private var contents: OathVaultContents?
    private var secret: OathWalletSecret? { contents?.activeWallets.first { $0.id == profile?.id } }
    private var encryptionKey: SymmetricKey?
    private var envelope: OathVaultEnvelope?
    private var profile: OathWalletProfile?
    private let suppliedDatabase: OathDatabase?
    private var walletMutation: UUID?
    private var securityAuthorization: (id: UUID, deadline: ContinuousClock.Instant)?
    private var biometricEnrollment: UUID?
    private var removalAuthorization: (id: UUID, action: OathWalletRemovalAction, deadline: ContinuousClock.Instant)?
    private var resetAuthorization: (id: UUID, deadline: ContinuousClock.Instant)?
    private let permissionClock: @Sendable () -> ContinuousClock.Instant
    private var permissionAuthorization: (id: UUID, scopes: [String: PermissionBatchScope], deadline: ContinuousClock.Instant)?
    private var resetting = false
    private var resetWorkInProgress = false
    private var legacyMigrationInProgress = false
    // Erasure-only authority, established after a failed migration. It never permits unlock, signing or reading recovery material.
    private var failedLegacyUpgradeFingerprint: String?
    private let resetEnvironment: any OathResetEnvironment

    init(storage: any OathVaultStorage = OathInstallationVaultStorage(),
         biometricStore: any OathBiometricCredentialStoring = OathBiometricCredentialStore(
            service: OathWalletVault.biometricService, installation: .shared),
         database: OathDatabase? = nil,
         resetEnvironment: any OathResetEnvironment = OathLocalResetEnvironment(),
         permissionClock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) {
        self.storage = storage
        self.biometricStore = biometricStore
        self.suppliedDatabase = database
        self.resetEnvironment = resetEnvironment
        self.permissionClock = permissionClock
    }


    func exists() throws -> Bool {
        guard !resetting else { throw OathWalletError.unavailable }
        return try storage.read("vault-v1") != nil
    }

    private static let legacyCompletionAccount = "legacy-upgrade-complete-v2"
    private static let emptyLegacyCompletionAccount = "legacy-upgrade-empty-welcome-v1"

    /// Old App Store data takes precedence over pre-release test vaults. Only a
    /// completion stamp written AFTER verified replacement suppresses migration.
    /// Do not inspect/decrypt the unrelated test vault before old authentication.
    func needsLegacyMigration(_ source: LegacyWalletSnapshot) throws -> Bool {
        guard let stamp = try storage.read(Self.legacyCompletionAccount),
              stamp == Data(try source.fingerprint.utf8) else { return true }
        if try storage.read("vault-v1") != nil { return false }
        // A verified all-skipped migration may intentionally return to Welcome.
        // Retain its source receipt so the preserved originals are not retried
        // at every launch or over a newly created wallet.
        return try storage.read(Self.emptyLegacyCompletionAccount) != stamp
    }

    /// Authentication is checked before any recovery material is read. No old
    /// record is updated/deleted. The encrypted payload contains the entire SQL
    /// commit so an interrupted upgrade can resume on the next authenticated launch.
    func migrateLegacy(_ source: LegacyWalletSnapshot, digits: [UInt8]?,
                       secrets: any OathLegacySecretReading = OathLegacyKeychain(),
                       verifySource: Bool = true, sourceURL: URL = OathLegacyUpgrade.sourceURL) async throws -> OathWalletProfile {
        guard !resetting, !legacyMigrationInProgress, walletMutation == nil else { throw OathWalletError.locked }
        legacyMigrationInProgress = true
        failedLegacyUpgradeFingerprint = nil
        defer { legacyMigrationInProgress = false }
        lock() // Invalidate test-vault keys and capabilities before the first await.
        let token = authenticationGeneration
        let fingerprint = try source.fingerprint
        do {
            if try !needsLegacyMigration(source) {
                if let digits { return try await unlock(digits: digits) }
                return try await unlockWithoutPasscode()
            }
            let db = try await database()
            try checkAuthentication(token)
            if source.security.appLockEnabled {
                guard let digits, let reference = source.security.passcodeReference else { throw OathWalletError.locked }
                let persisted = try storage.read("legacy-upgrade-attempts-v1")
                var attempts = try persisted.map { try JSONDecoder().decode(OathLegacyUnlockAttempts.self, from: $0) }
                    ?? OathLegacyUnlockAttempts(failures: source.security.failedAttempts,
                        blockedUntil: source.security.lockedUntil.map(Date.init(timeIntervalSince1970:)))
                if let until = attempts.blockedUntil, until > .now { throw OathWalletError.throttled(until) }
                // Persist before derivation: force quitting cannot reset attempts.
                attempts.recordAttempt(now: .now)
                let encoded = try JSONEncoder().encode(attempts)
                if persisted == nil { try storage.insert(encoded, account: "legacy-upgrade-attempts-v1") }
                else { try storage.update(encoded, account: "legacy-upgrade-attempts-v1") }
                let credential = try OathLegacyPasscodeCredential.read(reference: reference, secrets: secrets)
                guard try credential.matches(digits) else { throw OathWalletError.wrongPasscode }
                try storage.update(JSONEncoder().encode(OathLegacyUnlockAttempts(failures: 0, blockedUntil: nil)), account: "legacy-upgrade-attempts-v1")
            } else if digits != nil { throw OathWalletError.locked }
            try checkAuthentication(token)
            if verifySource {
                guard let current = try await LegacyWalletSource.read(at: sourceURL),
                      try current.fingerprint == source.fingerprint else { throw LegacyUpgradeError.sourceChanged }
            }
            try checkAuthentication(token)
            var (candidate, batch) = try OathLegacyUpgrade.prepare(source, secrets: secrets)
            batch.replacementID = UUID()
            candidate.legacyUpgrade = batch
            candidate.legacyBiometricTransition = source.security.biometricEnabled
            // Keep the same credential anchor used by prepare's vault references,
            // even when that wallet (or every wallet) has an unsupported mnemonic.
            // The lifecycle envelope supports an empty collection until the
            // verified result can reset its destination and route to Welcome.
            let root = try OathLegacyUpgrade.rootID(for: source)
            var salt = Data(count: 32)
            guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }) == errSecSuccess else {
                throw OathWalletError.unavailable
            }
            let key: SymmetricKey, protection: OathVaultProtection?
            if let digits {
                key = SymmetricKey(data: try OathPasscodeRecord.make(digits: digits, salt: Array(salt)).verifier)
                protection = nil
            } else {
                key = SymmetricKey(size: .bits256)
                protection = .init(wrappedKey: nil, deviceKey: key.withUnsafeBytes { Data($0) })
            }
            let sealed = try OathVaultEnvelope.seal(candidate, rootID: root, key: key, salt: salt,
                                                   iterations: 600_000, protection: protection, biometricAccess: false)
            // Authenticate the serialized result and verify every account again
            // before committing either store. No derived wallet is published yet.
            let reopened = try sealed.openContents(using: key)
            guard reopened.wallets.count == candidate.wallets.count,
                  reopened.legacyUpgrade == batch else { throw OathWalletError.corruptVault }
            try checkAuthentication(token)
            // The full candidate is verified before replacing any test keys. Never
            // use app reset here: it also deletes the recoverable legacy database.
            await resetEnvironment.suspend()
            try checkAuthentication(token)
            // Invalidate a previous source's stamp BEFORE replacing its vault. A
            // crash cannot pair an old completion stamp with a newer candidate.
            try storage.replace(Data(), account: Self.legacyCompletionAccount)
            try storage.replace(JSONEncoder().encode(sealed), account: "vault-v1")
            guard let persisted = try storage.read("vault-v1") else { throw OathWalletError.corruptVault }
            let verified = try JSONDecoder().decode(OathVaultEnvelope.self, from: persisted).openContents(using: key)
            guard verified.legacyUpgrade == batch else { throw OathWalletError.corruptVault }
            try await db.commitLegacyUpgrade(batch)
            let (current, recovered, profile) = try await reconcileUnlocked(sealed: sealed, key: key, opened: verified, token: token)
            try checkAuthentication(token)
            try await biometricStore.disable()
            await resetEnvironment.discardTestWalletConnections()
            try checkAuthentication(token)
            try storage.replace(JSONEncoder().encode(OathUnlockAttempts()), account: "unlock-attempts-v1")
            // A crash before this final stamp repeats old authentication and safely
            // rebuilds the candidate. No incomplete destination can open Home.
            try storage.replace(Data(try source.fingerprint.utf8), account: Self.legacyCompletionAccount)
            await resetEnvironment.reopen()
            try checkAuthentication(token)
            self.envelope = current; self.contents = recovered; self.encryptionKey = key; self.profile = profile
            return profile
        } catch {
            let authenticationFailure: Bool
            switch error as? OathWalletError {
            case .wrongPasscode, .throttled, .locked: authenticationFailure = true
            default: authenticationFailure = false
            }
            if !authenticationFailure, !(error is CancellationError), !Task.isCancelled, token == authenticationGeneration {
                failedLegacyUpgradeFingerprint = fingerprint
                OathDiagnostics.record(DiagnosticFailure("legacy_upgrade_failed"), component: "legacy_upgrade",
                    operation: "prepare_recovery", context: ["stage": "migration"])
            }
            throw error // Session reports the fixed failure stage without secrets.
        }
    }

    func legacyBiometricTransitionRequired() throws -> Bool {
        guard let contents else { throw OathWalletError.locked }
        return contents.legacyBiometricTransition == true
    }

    /// Called after successful re-enrollment or explicit "Use passcode only".
    /// The existing PIN remains enforced in both cases, including after restart.
    func finishLegacyBiometricTransition() throws {
        guard var contents, let envelope, let encryptionKey else { throw OathWalletError.locked }
        contents.legacyBiometricTransition = false
        let sealed = try OathVaultEnvelope.seal(contents, rootID: envelope.id, key: encryptionKey,
            salt: envelope.salt, iterations: envelope.iterations, protection: envelope.protection,
            biometricAccess: envelope.biometricAccess)
        try storage.update(JSONEncoder().encode(sealed), account: "vault-v1")
        self.contents = contents; self.envelope = sealed
    }

    /// Read-only Home data for a cold launch under the native lock. The envelope
    /// supplies only the wallet identity: this never decrypts the wallet, caches
    /// a key, resets attempts, or grants access to any authenticated operation.
    func lockedDisplaySnapshot() async throws -> WalletSnapshot? {
        guard let data = try storage.read("vault-v1") else { return nil }
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        let database = try await database()
        let selection = try await database.settings()["activeWalletID"]
        let records = try await database.wallets().filter { sealed.memberIDs.map(\.uuidString).contains($0.id) }
        guard let wallet = records.first(where: { $0.id == selection }) ?? records.first,
              let selectedID = UUID(uuidString: wallet.id) else { return nil }
        guard wallet.vaultReference == OathVaultContents.reference(for: selectedID, rootID: sealed.id) else {
            throw OathWalletError.corruptVault
        }
        return try await database.snapshot(walletID: wallet.id,
            currency: Locale.autoupdatingCurrent.currency?.identifier ?? "USD")
    }

    func unlockedProfile() throws -> OathWalletProfile {
        guard let profile, contents != nil, encryptionKey != nil else { throw OathWalletError.locked }
        return profile
    }

    func create(digits: [UInt8], importing phrase: OathValidatedMnemonic?, privateKey: OathImportedPrivateKey? = nil, multisig: BackupWallet.BitcoinMultisig? = nil, solanaMultisig: BackupWallet.SolanaMultisig? = nil, tronMultisig: BackupWallet.TronMultisig? = nil, xrplMultisig: BackupWallet.XrplMultisig? = nil, stellarMultisig: BackupWallet.StellarMultisig? = nil, aptosMultisig: BackupWallet.AptosMultisig? = nil, suiMultisig: BackupWallet.SuiMultisig? = nil, nearMultisig: BackupWallet.NearMultisig? = nil, evmMultisig: BackupWallet.EVMMultisig? = nil, tonMultisig: BackupWallet.TonMultisig? = nil, thorchainMultisig: BackupWallet.ThorchainMultisig? = nil) async throws {
        guard evmMultisig == nil || (tonMultisig == nil && thorchainMultisig == nil && nearMultisig == nil && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard tonMultisig == nil || (thorchainMultisig == nil && nearMultisig == nil && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard thorchainMultisig == nil || (nearMultisig == nil && suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard nearMultisig == nil || (suiMultisig == nil && aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard suiMultisig == nil || (aptosMultisig == nil && stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard aptosMultisig == nil || (stellarMultisig == nil && xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard stellarMultisig == nil || (xrplMultisig == nil && solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard xrplMultisig == nil || (solanaMultisig == nil && tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard solanaMultisig == nil || (tronMultisig == nil && multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard tronMultisig == nil || (multisig == nil && phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard multisig == nil || (phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard phrase == nil || privateKey == nil else { throw OathWalletError.invalidPrivateKey }
        let token = authenticationGeneration
        // Finish opening/migrating before committing any new protected wallet.
        // A schema or protected-data error must fail before this point of no return.
        _ = try await database()
        guard token == authenticationGeneration else { throw CancellationError() }
        guard try !exists() else { throw OathPasscodeSaveError.alreadyConfigured }
        try Task.checkCancellation()
        var candidate: OathWalletSecret
        if let evmMultisig { candidate = try OathWalletEngine.multisig(evmMultisig) }
        else if let tonMultisig { candidate = try OathWalletEngine.multisig(tonMultisig) }
        else if let thorchainMultisig { candidate = try OathWalletEngine.multisig(thorchainMultisig) }
        else if let nearMultisig { candidate = try OathWalletEngine.multisig(nearMultisig) }
        else if let suiMultisig { candidate = try OathWalletEngine.multisig(suiMultisig) }
        else if let aptosMultisig { candidate = try OathWalletEngine.multisig(aptosMultisig) }
        else if let stellarMultisig { candidate = try OathWalletEngine.multisig(stellarMultisig) }
        else if let xrplMultisig { candidate = try OathWalletEngine.multisig(xrplMultisig) }
        else if let solanaMultisig { candidate = try OathWalletEngine.multisig(solanaMultisig) }
        else if let tronMultisig { candidate = try OathWalletEngine.multisig(tronMultisig) }
        else if let multisig { candidate = try OathWalletEngine.multisig(multisig) }
        else if let privateKey { candidate = try OathWalletEngine.imported(privateKey) }
        else if let phrase { candidate = try OathWalletEngine.imported(phrase) }
        else { candidate = try OathWalletEngine.create() }
        candidate.imported = phrase != nil || privateKey != nil
        candidate.createdWithCustomization = true
        let derived = try OathWalletEngine.profile(for: candidate)
        let (sealed, key) = try OathVaultEnvelope.seal(candidate, digits: digits)
        try Task.checkCancellation()
        // One insert commits the wallet AND its passcode, or neither. The
        // installation boundary has already removed stale prototype records.
        try storage.insert(JSONEncoder().encode(sealed), account: "vault-v1")
        let stored = try await storedProfile(for: candidate, rootID: candidate.id, derived: derived, token: token)
        try Task.checkCancellation()
        guard token == authenticationGeneration else { throw CancellationError() }
        contents = OathVaultContents(wallets: [candidate], lifecycleVersion: !candidate.isMultisig && !candidate.isLocalMnemonic ? nil : 1); encryptionKey = key; envelope = sealed; profile = stored
        // The encrypted local commit completes wallet creation.
    }

    func unlock(digits: [UInt8], now: Date = .now) async throws -> OathWalletProfile {
        let token = authenticationGeneration
        let (sealed, key, opened) = try openWithPasscode(digits, now: now)
        let (current, recovered, derived) = try await reconcileUnlocked(sealed: sealed, key: key, opened: opened, token: token)
        try checkAuthentication(token)
        contents = recovered; encryptionKey = key; envelope = current; profile = derived
        return derived
    }

    private func openWithPasscode(_ digits: [UInt8], now: Date) throws
        -> (OathVaultEnvelope, SymmetricKey, OathVaultContents) {
        guard !resetting else { throw OathWalletError.locked }
        try Task.checkCancellation()
        let data = try storage.read("vault-v1")
        guard let data else { throw OathWalletError.unavailable }
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        let attemptsData = try storage.read("unlock-attempts-v1")
        var attempts = try attemptsData.map { try JSONDecoder().decode(OathUnlockAttempts.self, from: $0) } ?? .init()
        if let until = attempts.blockedUntil, now < until { throw OathWalletError.throttled(until) }
        // Charge only a credential attempt, after this reader accepts the
        // envelope header. Persist before checking the PIN to resist restarts.
        let key = try sealed.key(for: digits) {
            attempts.recordAttempt(now: now)
            try saveAttempts(attempts, existing: attemptsData != nil)
        }
        // Modern envelopes authenticate the PIN while unwrapping the data key.
        // Once that succeeds, payload corruption is not another incorrect PIN.
        // Legacy envelopes authenticate the PIN only when opening the payload.
        let authenticatedPIN = sealed.protection?.wrappedKey != nil
        if authenticatedPIN { try saveAttempts(.init(), existing: true) }
        let opened: OathVaultContents
        do {
            opened = try sealed.openContents(using: key) {
                // A legacy PIN is proven when AES authenticates the bytes.
                // Decoding the wallet afterwards can fail independently.
                if !authenticatedPIN { try saveAttempts(.init(), existing: true) }
            }
        }
        catch OathWalletError.wrongPasscode where authenticatedPIN {
            // diagnostics: authenticated-payload-failure
            // openContents already records the original cryptographic failure.
            // Keep the vault closed and preserve its ciphertext for recovery.
            throw OathWalletError.corruptVault
        }
        try Task.checkCancellation()
        return (sealed, key, opened)
    }

    func lock() {
        authenticationGeneration = UUID()
        permissionAuthorization = nil
        securityAuthorization = nil
        biometricEnrollment = nil
        resetAuthorization = nil
        removalAuthorization = nil
        contents = nil; encryptionKey = nil; envelope = nil; profile = nil
        walletMutation = nil
    }

    /// One fresh authentication covers only these reviewed, removal-only plans.
    /// No PIN is retained, and lock/security changes invalidate the capability.
    func authorizePermissionBatch(_ scopes: [PermissionBatchScope], digits: [UInt8]?, reason: String) async throws -> UUID {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              !scopes.isEmpty, scopes.count <= PermissionBatchScope.maximumItems, Set(scopes.map(\.sendID)).count == scopes.count,
              Set(scopes.map(\.walletID)).count == 1 else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        guard opened.activeWallets.contains(where: { $0.id.uuidString == scopes[0].walletID }) else { throw OathWalletError.locked }
        let id = UUID()
        permissionAuthorization = (id, Dictionary(uniqueKeysWithValues: scopes.map { ($0.sendID, $0) }),
                                   permissionClock().advanced(by: .seconds(1_800)))
        return id
    }
    func endPermissionBatch(_ id: UUID) {
        if permissionAuthorization?.id == id { permissionAuthorization = nil }
    }
    func permissionBatchIsAuthorized(_ id: UUID) -> Bool {
        guard let grant = permissionAuthorization else { return false }
        return grant.id == id && permissionClock() <= grant.deadline && encryptionKey != nil && !resetting
    }
    // Scope consumption is single-use, but it does not outlive the batch grant.
    // Recheck after suspension and before returning any newly signed bytes.
    private func checkPermissionAuthorization(_ id: UUID?) throws {
        if let id, !permissionBatchIsAuthorized(id) { throw PermissionError.changed }
    }
    private func consumePermissionAuthorization(_ id: UUID, scope: PermissionBatchScope) throws {
        guard var grant = permissionAuthorization, grant.id == id, permissionClock() <= grant.deadline,
              let reviewed = grant.scopes[scope.sendID], reviewed.permits(scope) else { throw PermissionError.changed }
        grant.scopes.removeValue(forKey: scope.sendID)
        permissionAuthorization = grant
    }

    // Public metadata has its own database isolation. Do not queue its reads
    // behind key derivation or post-unlock vault work; no vault state is read.
    nonisolated func database() async throws -> OathDatabase {
        if let suppliedDatabase { return suppliedDatabase }
        return try await OathDataEnvironment.shared.database()
    }

    /// Public descriptors are derived inside the unlocked vault. The network
    /// scanner never receives recovery material or private extended keys.
    func prepareBitcoin(accountID: String) async throws {
        guard let contents, encryptionKey != nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let db = try await database()
        guard let account = try await db.bitcoinAccount(id: accountID),
              let secret = contents.activeWallets.first(where: { $0.id.uuidString == account.walletID }),
              let network = UTXONetwork(rawValue: account.networkID), account.accountIndex >= 0, account.accountIndex < 0x8000_0000 else { throw OathWalletError.locked }
        try checkAuthentication(token)
        if try await db.bitcoinState(accountID: accountID) != nil { return }
        let descriptor = try OathWalletEngine.bitcoinDescriptor(for: secret, account: UInt32(account.accountIndex), network: network)
        try checkAuthentication(token)
        try await db.prepareBitcoin(accountID: accountID, descriptor: descriptor)
        try checkAuthentication(token)
    }

    /// Authorization is bound to this immutable, reserved plan. Secrets stay
    /// inside the vault and never enter the send model, database or diagnostics.
    func signBitcoinSend(sendID: String, quote: OathBitcoinQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> BitcoinSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.state == "queued",
              try await db.bitcoinSendPlan(sendID: sendID) == quote.plan else { throw BitcoinSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == quote.walletID }) else { throw OathWalletError.locked }
        let accounts = try await db.accounts(walletID: quote.walletID).filter { $0.networkID == quote.plan.chain.rawValue }
        let reserved = try await db.reservedOutputs(sendID: sendID)
        guard Set(reserved.map { "\($0.transactionHash):\($0.outputIndex)" }) == Set(quote.plan.coins.map(\.id)),
              let changeAccount = accounts.first(where: { $0.id == quote.accountID }), changeAccount.accountIndex >= 0,
              changeAccount.accountIndex < 0x8000_0000 else { throw BitcoinSendError.changed }
        let descriptor = try OathWalletEngine.bitcoinDescriptor(for: wallet, account: UInt32(changeAccount.accountIndex), network: quote.plan.chain)
        guard let branch = descriptor.branches.first(where: { $0.id == quote.plan.change.branchID }),
              try BitcoinKeys.addresses(branch: branch, range: quote.plan.change.index..<(quote.plan.change.index + 1)).first == quote.plan.change else {
            throw BitcoinSendError.changed
        }
        try checkAuthentication(token)
        do {
            let signed = try OathWalletEngine.signBitcoin(quote.plan, secret: wallet, accounts: accounts)
            try checkAuthentication(token)
            return signed
        } catch { OathDiagnostics.record(error);
            Task { await OathSendDiagnostics.shared.record(network: quote.plan.chain.rawValue, stage: "sign", error: error, inputCount: quote.plan.coins.count) }
            throw error
        }
    }

    func signSuiSend(sendID: String, quote: OathSuiQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> SuiSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.suiSendPlan(sendID:sendID) == quote.plan else { throw SuiSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signSui(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    func signXrplSend(sendID: String, quote: OathXrplQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> XrplSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.xrplSendPlan(sendID:sendID) == quote.plan else { throw XrplSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signXrpl(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    func signStellarSend(sendID: String, quote: OathStellarQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> StellarSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.stellarSendPlan(sendID:sendID) == quote.plan else { throw StellarSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signStellar(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    /// Public policy only; private keys never leave authenticated signing/recovery.
    func solanaMultisigPolicy(walletID: String) throws -> SolanaMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.solanaMultisig?.policy()
    }

    func evmMultisigPolicy(walletID: String) throws -> EVMMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.evmMultisig?.policy()
    }
    func tonMultisigPolicy(walletID: String) throws -> TonMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.tonMultisig?.policy()
    }
    func thorchainMultisigPolicy(walletID: String) throws -> ThorchainMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.thorchainMultisig?.policy()
    }
    func nearMultisigPolicy(walletID: String) throws -> NearMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.nearMultisig?.policy()
    }
    func suiMultisigPolicy(walletID: String) throws -> SuiMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.suiMultisig?.policy()
    }
    func aptosMultisigPolicy(walletID: String) throws -> AptosMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.aptosMultisig?.policy()
    }
    func stellarMultisigPolicy(walletID: String) throws -> StellarMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.stellarMultisig?.policy()
    }
    func xrplMultisigPolicy(walletID: String) throws -> XrplMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.xrplMultisig?.policy()
    }

    func tronMultisigPolicy(walletID: String) throws -> TronMultisigPolicy? {
        guard encryptionKey != nil, let wallet = contents?.activeWallets.first(where: { $0.id.uuidString == walletID }) else {
            throw OathWalletError.locked
        }
        return try wallet.tronMultisig?.policy()
    }

    func signTronSend(sendID: String, quote: OathTronQuote, digits: [UInt8]?, reason: String, permissionAuthorization: UUID? = nil, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> TronSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if let permissionAuthorization {
            let scope = try PermissionBatchScope.tron(sendID: sendID, walletID: quote.walletID,
                accountID: quote.accountID, plan: quote.plan)
            try consumePermissionAuthorization(permissionAuthorization, scope: scope)
            guard let contents else { throw OathWalletError.locked }
            opened = contents
        } else if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.tronSendPlan(sendID:sendID) == quote.plan else { throw TronSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        try checkPermissionAuthorization(permissionAuthorization)
        let signed = try OathWalletEngine.signTron(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        try checkPermissionAuthorization(permissionAuthorization)
        return signed
    }

    /// Authorize the exact persisted NEAR plan before accessing its signing key.
    func signNearSend(sendID: String, quote: OathNearQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> NearSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.nearSendPlan(sendID:sendID) == quote.plan else { throw NearSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signNear(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    /// Authorize the exact persisted Polkadot plan before accessing its signing key.
    func signPolkadotSend(sendID: String, quote: OathPolkadotQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> PolkadotSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.polkadotSendPlan(sendID:sendID) == quote.plan else { throw PolkadotSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signPolkadot(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    /// Return only the selected account’s public key for a read-only quote.
    func nearPublicKey(walletID:String,accountID:String) async throws -> Data {
        guard encryptionKey != nil,let contents,walletMutation==nil,!resetting else { throw OathWalletError.locked }
        let token=authenticationGeneration,db=try await database()
        guard let wallet=contents.activeWallets.first(where:{$0.id.uuidString==walletID}),
              let account=try await db.accounts(walletID:walletID).first(where:{$0.id==accountID && $0.networkID=="near"}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        return try OathWalletEngine.nearPublicKey(secret:wallet,account:account)
    }

    /// Authorize the exact persisted THORChain plan before accessing its signing key.
    func signThorchainSend(sendID: String, quote: OathThorchainQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> ThorchainSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.thorchainSendPlan(sendID:sendID) == quote.plan else { throw ThorchainSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signThorchain(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    /// Return only the selected account’s public key for a read-only quote.
    func thorchainPublicKey(walletID:String,accountID:String) async throws -> Data {
        guard encryptionKey != nil,let contents,walletMutation==nil,!resetting else { throw OathWalletError.locked }
        let token=authenticationGeneration,db=try await database()
        guard let wallet=contents.activeWallets.first(where:{$0.id.uuidString==walletID}),
              let account=try await db.accounts(walletID:walletID).first(where:{$0.id==accountID && $0.networkID=="thorchain"}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        return try OathWalletEngine.thorchainPublicKey(secret:wallet,account:account)
    }

    /// Exact reviewed Solana request; the CAIP cluster is validated before this
    /// boundary. Fresh authentication and selected derivation are checked again.
    func signWalletConnectXrpl(walletID: String, accountID: String, request: WalletConnectXrplRequest,
        review: WalletConnectXrplReview, digits: [UInt8]?, reason: String) async throws -> WalletConnectXrplSigned {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw XrplSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try await OathWalletEngine.signWalletConnectXrpl(request,review:review,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectStellar(walletID: String, accountID: String, request: WalletConnectStellarRequest,
        review: WalletConnectStellarReview, digits: [UInt8]?, reason: String) async throws -> WalletConnectStellarSigned {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw StellarSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectStellar(request,review:review,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectNear(walletID: String, accountID: String, request: WalletConnectNearRequest,
        review: WalletConnectNearReview, digits: [UInt8]?, reason: String) async throws -> NearJSON {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw NearSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectNear(request,review:review,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectSui(walletID: String, accountID: String, request: WalletConnectSuiRequest,
        review: WalletConnectSuiReview?, digits: [UInt8]?, reason: String) async throws -> WalletConnectSuiSignature {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw SuiSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectSui(request,review:review,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    func suiPublicKey(walletID:String,accountID:String) async throws -> Data {
        guard encryptionKey != nil, let contents, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration, db = try await database()
        guard let wallet = contents.activeWallets.first(where:{$0.id.uuidString == walletID}),
              let account = try await db.account(accountID), account.walletID == walletID else { throw SuiSendError.wrongOwner }
        try checkAuthentication(token)
        return try OathWalletEngine.suiPublicKey(secret:wallet,account:account)
    }

    func signWalletConnectPolkadot(walletID: String, accountID: String, request: WalletConnectPolkadotRequest,
        review: PolkadotConnectReview?, digits: [UInt8]?, reason: String) async throws -> TronJSON {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw PolkadotSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectPolkadot(request,review:review,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectTron(walletID: String, accountID: String, request: WalletConnectTronRequest,
        review: WalletConnectTronReview?, digits: [UInt8]?, reason: String) async throws -> TronJSON {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw TronSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectTron(request,review:review,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectBitcoin(walletID: String, accountID: String, request: BitcoinConnectRequest,
        plan: BitcoinConnectPlan?, address: BitcoinDerivedAddress?, digits: [UInt8]?, reason: String) async throws -> OathBitcoinConnectSignature {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else { guard let contents else { throw OathWalletError.locked }; opened = contents }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where:{ $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw BitcoinConnectError.wrongAccount }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectBitcoin(request,plan:plan,address:address,secret:wallet,account:account)
        try checkAuthentication(token)
        return result
    }

    /// Sign the reviewed TON request after fresh authentication and ownership checks.
    func signWalletConnectTon(walletID: String, accountID: String, request: WalletConnectTonRequest,
                              plan: WalletConnectTonPlan?, digits: [UInt8]?, reason: String) async throws -> OathTonWalletConnectSignature {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw TonSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectTon(request, plan: plan, secret: wallet, account: account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectTonProof(walletID: String, accountID: String, request: WalletConnectTonProofRequest,
                              timestamp: UInt64, digits: [UInt8]?, reason: String) async throws -> Data {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID else { throw TonSendError.wrongOwner }
        try checkAuthentication(token)
        let result = try OathWalletEngine.signWalletConnectTonProof(request, timestamp: timestamp, secret: wallet, account: account)
        try checkAuthentication(token)
        return result
    }

    func signWalletConnectSolana(walletID: String, accountID: String, request: WalletConnectSolanaRequest,
                                 digits: [UInt8]?, reason: String) async throws -> WalletConnectSolanaSigned {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == walletID }) else { throw OathWalletError.locked }
        let account = try await db.solanaSigningAccount(accountID: accountID)
        guard account.walletID == walletID, account.address == request.account else { throw SolanaSendError.changed }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signWalletConnectSolana(request, secret: wallet, account: account)
        try checkAuthentication(token)
        return signed
    }

    func signSolanaSend(sendID: String, quote: OathSolanaQuote, digits: [UInt8]?, reason: String, permissionAuthorization: UUID? = nil, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> SolanaSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if let permissionAuthorization {
            let scope = try PermissionBatchScope.solana(sendID: sendID, walletID: quote.walletID,
                accountID: quote.accountID, plan: quote.plan)
            try consumePermissionAuthorization(permissionAuthorization, scope: scope)
            guard let contents else { throw OathWalletError.locked }
            opened = contents
        } else if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.solanaSendPlan(sendID:sendID) == quote.plan else { throw SolanaSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let original = try await db.account(quote.accountID) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let account = try await db.solanaSigningAccount(accountID:quote.accountID)
        guard original.walletID==quote.walletID,account.address==quote.plan.sender else { throw SolanaSendError.changed }
        try checkAuthentication(token)
        try checkPermissionAuthorization(permissionAuthorization)
        let signed = try OathWalletEngine.signSolana(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        try checkPermissionAuthorization(permissionAuthorization)
        return signed
    }


    /// Fresh authentication for the exact reviewed EIP-191 message. Connecting
    /// a dapp cannot grant this operation, and a lock invalidates it in flight.
    func signWalletConnectMessage(walletID: String, accountID: String, message: Data,
                                  digits: [UInt8]?, reason: String) async throws -> String {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              message.count <= 4_096 else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID,
              OathImportChain(rawValue: account.networkID)?.isEVM == true else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signature = try OathWalletEngine.signWalletConnectMessage(message, secret: wallet, account: account)
        try checkAuthentication(token)
        return signature
    }

    /// EIP-712 fields have already been decoded into an immutable reviewed
    /// value. Authenticate again; an unlocked connection is never signing consent.
    func signWalletConnectTypedData(walletID: String, accountID: String, data: WalletConnectTypedData,
                                    digits: [UInt8]?, reason: String) async throws -> String {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID,
              OathImportChain(rawValue: account.networkID)?.isEVM == true else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signature = try OathWalletEngine.signWalletConnectTypedData(data, secret: wallet, account: account)
        try checkAuthentication(token)
        return signature
    }

    /// Connection consent never authorizes a transaction. Authenticate the
    /// exact immutable review again and invalidate access on lock/reset/remove.
    func signThorchainWalletConnect(walletID: String, accountID: String, request: ThorchainWalletConnectRequest,
                                   digits: [UInt8]?, reason: String) async throws -> SolanaJSON {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              request.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits, now: .now).2 }
            else { opened = try await openWithBiometrics(reason: reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        let db = try await database()
        guard let wallet = opened.activeWallets.first(where: { $0.id.uuidString == walletID }),
              let account = try await db.account(accountID), account.walletID == walletID,
              account.networkID == "thorchain", account.address == request.sender else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let response = try OathWalletEngine.signThorchainWalletConnect(request, secret: wallet, account: account)
        try checkAuthentication(token)
        return response
    }

    func signArcSend(sendID: String, quote: OathArcQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> ArcSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.arcSendPlan(sendID:sendID) == quote.plan else { throw ArcSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signArc(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }


    func signEVMSend(sendID: String, quote: OathEVMQuote, digits: [UInt8]?, reason: String, permissionAuthorization: UUID? = nil, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> EVMSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              !quote.plan.network.isTestnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if let permissionAuthorization {
            let scope = try PermissionBatchScope.evm(sendID: sendID, walletID: quote.walletID,
                accountID: quote.accountID, plan: quote.plan)
            try consumePermissionAuthorization(permissionAuthorization, scope: scope)
            guard let contents else { throw OathWalletError.locked }
            opened = contents
        } else if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.evmSendPlan(sendID:sendID) == quote.plan else { throw EVMSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        try checkPermissionAuthorization(permissionAuthorization)
        let signed = try OathWalletEngine.signEVM(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        try checkPermissionAuthorization(permissionAuthorization)
        return signed
    }


    func signAptosSend(sendID: String, quote: OathAptosQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> AptosSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.aptosSendPlan(sendID:sendID) == quote.plan else { throw AptosSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signAptos(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    /// Return only the selected account’s public key for a read-only quote.
    func aptosPublicKey(walletID:String,accountID:String) async throws -> Data {
        guard encryptionKey != nil,let contents,walletMutation==nil,!resetting else { throw OathWalletError.locked }
        let token=authenticationGeneration,db=try await database()
        guard let wallet=contents.activeWallets.first(where:{$0.id.uuidString==walletID}),
              let account=try await db.accounts(walletID:walletID).first(where:{$0.id==accountID && $0.networkID=="aptos"}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        return try OathWalletEngine.aptosPublicKey(secret:wallet,account:account)
    }

    func signTonSend(sendID: String, quote: OathTonQuote, digits: [UInt8]?, reason: String, prepare: (@Sendable () async throws -> Void)? = nil) async throws -> TonSignedSend {
        guard encryptionKey != nil, let envelope, profile != nil, walletMutation == nil, !resetting,
              quote.plan.network == .mainnet else { throw OathWalletError.locked }
        let token = authenticationGeneration
        // Start independent preparation without putting it ahead of Face ID.
        // Authentication stays inside this invocation and cannot be reused.
        async let prepared: Void? = prepare?()
        let opened: OathVaultContents
        if envelope.passcodeEnabled {
            if let digits { opened = try openWithPasscode(digits,now:.now).2 }
            else { opened = try await openWithBiometrics(reason:reason).2 }
        } else {
            guard let contents else { throw OathWalletError.locked }; opened = contents
        }
        try checkAuthentication(token)
        _ = try await prepared
        let db = try await database()
        guard let send = try await db.send(sendID), send.walletID == quote.walletID, send.accountID == quote.accountID,
              send.assetID == quote.assetID, send.state == "queued",
              try await db.tonSendPlan(sendID:sendID) == quote.plan else { throw TonSendError.changed }
        try checkAuthentication(token)
        try quote.plan.validate()
        guard let wallet = opened.activeWallets.first(where:{$0.id.uuidString == quote.walletID}),
              let account = try await db.accounts(walletID:quote.walletID).first(where:{$0.id == quote.accountID}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        let signed = try OathWalletEngine.signTon(quote.plan,secret:wallet,account:account)
        try checkAuthentication(token)
        return signed
    }

    /// Return only the selected account’s public key for a read-only quote.
    func tonPublicKey(walletID:String,accountID:String) async throws -> Data {
        guard encryptionKey != nil,let contents,walletMutation==nil,!resetting else { throw OathWalletError.locked }
        let token=authenticationGeneration,db=try await database()
        guard let wallet=contents.activeWallets.first(where:{$0.id.uuidString==walletID}),
              let account=try await db.accounts(walletID:walletID).first(where:{$0.id==accountID && $0.networkID=="ton"}) else { throw OathWalletError.locked }
        try checkAuthentication(token)
        return try OathWalletEngine.tonPublicKey(secret:wallet,account:account)
    }

    /// Resolve every Solana receive entry point through the vault, including
    /// token sheets. A lock or wallet switch invalidates an in-flight request.
    func solanaReceiveState(accountID: String, selecting path: String? = nil) async throws -> SolanaReceiveState {
        guard let secret, encryptionKey != nil, let walletID = profile?.id else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let db = try await database()
        guard let account = try await db.accounts(walletID: walletID.uuidString).first(where: { $0.id == accountID }),
              account.networkID == "solana" else { throw OathWalletError.unavailable }
        try checkAuthentication(token)
        let state = try await prepareSolanaReceive(account: account, secret: secret, database: db, token: token)
        guard profile?.id == walletID else { throw CancellationError() }
        guard let path else { return state }
        let selected = try await db.selectSolanaReceivePath(accountID: accountID, path: path)
        try checkAuthentication(token)
        guard profile?.id == walletID else { throw CancellationError() }
        return selected
    }

    private func prepareSolanaReceive(account: AccountRecord, secret: OathWalletSecret,
                                      database: OathDatabase, token: UUID) async throws -> SolanaReceiveState {
        try checkAuthentication(token)
        if let existing = try await database.solanaReceiveState(accountID: account.id) {
            try checkAuthentication(token)
            return existing
        }
        try checkAuthentication(token)
        let addresses = try OathWalletEngine.solanaReceiveAddresses(for: secret, account: account)
        let restoredPreference = secret.restoration?.accounts.first {
            $0.network == "solana" && $0.index == account.accountIndex
        }?.solanaReceivePath
        let preferred = restoredPreference ?? addresses.first!.path // Phantom first; a raw key has one address.
        let state = try await database.prepareSolanaReceive(accountID: account.id, addresses: addresses, preferredPath: preferred)
        try checkAuthentication(token)
        return state
    }

    /// Export the requested wallet, including inactive wallets, without ever
    /// passing recovery words or the app's PIN to the UI or cloud-file layer.
    func encryptedCloudBackup(walletID: String, password: String) async throws -> Data {
        let token = authenticationGeneration
        guard let id = UUID(uuidString: walletID), let envelope, encryptionKey != nil,
              let wallet = contents?.activeWallets.first(where: { $0.id == id }) else { throw OathWalletError.locked }
        guard !wallet.isLocalMnemonic else { throw OathWalletError.unavailable }
        let db = try await database()
        let snapshot = try await db.snapshot(walletID: walletID, currency: "USD")
        try checkAuthentication(token)
        guard snapshot.wallet.vaultReference == OathVaultContents.reference(for: id, rootID: envelope.id) else {
            throw OathWalletError.corruptVault
        }
        var portableAccounts: [BackupWallet.Account] = []
        for account in snapshot.accounts {
            let state = account.networkID == "solana" ? try await prepareSolanaReceive(account: account, secret: wallet, database: db, token: token) : nil
            portableAccounts.append(.init(network: account.networkID, derivationPath: account.derivationPath, index: account.accountIndex,
                solanaReceivePath: wallet.privateKey == nil ? state?.selected.path : nil))
        }
        let portable = BackupWallet(id: id, name: snapshot.wallet.name, mnemonic: wallet.mnemonic,
            language: wallet.language, createdAt: wallet.createdAt,
            accounts: portableAccounts,
            colorHex: snapshot.wallet.colorHex,
            privateKey: wallet.privateKey.map { .init(bytes: $0.bytes,
                networks: $0.networks.allSatisfy(\.isEVM) ? Array(Set(snapshot.accounts.map(\.networkID))).sorted() : $0.networks.map(\.id),
                compressed: $0.compressed, bitcoinExtendedKey: $0.bitcoinExtendedKey, dogecoinExtendedKey: $0.dogecoinExtendedKey,
                litecoinExtendedKey: $0.litecoinExtendedKey, bitcoinCashExtendedKey: $0.bitcoinCashExtendedKey) },
            passphrase: wallet.passphrase,
            legacyPassphrase: wallet.passphrase != nil && (wallet.legacy != nil || wallet.restoration?.legacyPassphrase == true) ? true : nil,
            parentWalletID: wallet.parentWalletID, bitcoinMultisig: wallet.bitcoinMultisig, tronMultisig: wallet.tronMultisig, solanaMultisig: wallet.solanaMultisig, xrplMultisig: wallet.xrplMultisig, stellarMultisig: wallet.stellarMultisig, aptosMultisig: wallet.aptosMultisig, suiMultisig: wallet.suiMultisig, nearMultisig: wallet.nearMultisig, evmMultisig: wallet.evmMultisig, tonMultisig: wallet.tonMultisig, thorchainMultisig: wallet.thorchainMultisig)
        let data = try await Task.detached(priority: .userInitiated) {
            try BackupDocument.seal(portable, password: password)
        }.value
        try checkAuthentication(token)
        _ = try recoveryWalletID(walletID)
        return data
    }

    /// Derive at creation or once when enrolling a newly supported chain.
    /// Ordinary wallet reads and refreshes use the persisted public accounts.
    private func storedProfile(for secret: OathWalletSecret, rootID: UUID,
                               derived: OathWalletProfile? = nil, token: UUID) async throws -> OathWalletProfile {
        let db = try await database()
        try checkAuthentication(token)
        let id = secret.id.uuidString
        let reference = OathVaultContents.reference(for: secret.id, rootID: rootID)
        if try await db.wallet(id) == nil {
            try checkAuthentication(token)
            let initial = try derived ?? OathWalletEngine.profile(for: secret)
            try await db.importWalletIfNeeded(
                WalletRecord(id: id, name: secret.legacy?.wallet.name ?? secret.restoration?.name ?? "", kind: secret.electrum != nil ? (secret.electrum!.kind.isTwoFactor ? "electrum2fa" : "electrum") : secret.aezeed != nil ? "aezeed" : secret.evmMultisig != nil ? "evmMultisig" : secret.tonMultisig != nil ? "tonMultisig" : secret.thorchainMultisig != nil ? "thorchainMultisig" : secret.nearMultisig != nil ? "nearMultisig" : secret.suiMultisig != nil ? "suiMultisig" : secret.aptosMultisig != nil ? "aptosMultisig" : secret.stellarMultisig != nil ? "stellarMultisig" : secret.xrplMultisig != nil ? "xrplMultisig" : secret.solanaMultisig != nil ? "solanaMultisig" : secret.tronMultisig != nil ? "tronMultisig" : secret.bitcoinMultisig != nil ? (secret.bitcoinMultisig?.chainID == "dogecoin" ? "dogecoinMultisig" : secret.bitcoinMultisig?.chainID == "bitcoincash" ? "bitcoinCashMultisig" : secret.bitcoinMultisig?.chainID == "litecoin" ? "litecoinMultisig" : "bitcoinMultisig") : secret.privateKey != nil ? "privateKey" :
                             (secret.passphrase != nil ? "passphrase" : (secret.imported == true ? "imported" : "hd")),
                             vaultReference: reference, createdAt: secret.createdAt.timeIntervalSince1970,
                             backedUp: secret.backedUp, colorHex: secret.restoration?.colorHex,
                             needsCustomization: secret.createdWithCustomization == true,
                             nameGroup: secret.isDerivedWallet ? "passphrase" : secret.isLocalMnemonic ? "imported" : secret.isMultisig ? "multisig" : secret.passphrase != nil ? "passphrase" : (secret.restoration != nil ? "restored" : secret.privateKey?.networks.first.map { "network:" + $0.id }),
                             parentWalletID: secret.parentWalletID?.uuidString, nameIndex: secret.passphraseIndex ?? 0),
                accounts: initial.addresses.map {
                    AccountRecord(id: id + ":" + $0.chain.id + ":" + String($0.accountIndex), walletID: id, networkID: $0.chain.id,
                                  address: $0.address, derivationPath: $0.path, accountIndex: $0.accountIndex)
                })
        }
        try checkAuthentication(token)
        // Add only the newly supported public account on authenticated unlock.
        // Imported private keys and explicitly scoped backups retain their scope.
        if !secret.isLocalMnemonic, !secret.isMultisig, secret.privateKey == nil, secret.restoration == nil,
           let wallet = try await db.wallet(id), wallet.deletedAt == nil {
            let existing = Set(try await db.accounts(walletID: id).map(\.networkID))
            let missing = Set([OathImportChain.thorchain, .polkadot].filter { !existing.contains($0.id) })
            if !missing.isEmpty {
                let addition = try OathWalletEngine.profile(for: secret, chains: missing)
                try checkAuthentication(token)
                try await db.importWalletIfNeeded(wallet, accounts: addition.addresses.map {
                    AccountRecord(id: id + ":" + $0.chain.id + ":" + String($0.accountIndex), walletID: id, networkID: $0.chain.id,
                                  address: $0.address, derivationPath: $0.path, accountIndex: $0.accountIndex)
                })
                try checkAuthentication(token)
            }
        }
        try await db.enrollAnkrNetworks(walletID: id)
        // Prepare public receive policies before publishing a created/imported
        // wallet. Receive must not first queue behind unrelated vault work.
        // Saved accounts, HD lookahead/change and Solana variants atomically
        // generate their public QR cache through the shared database triggers.
        guard let storedWallet = try await db.wallet(id), storedWallet.vaultReference == reference else {
            throw OathWalletError.corruptVault
        }
        for account in try await db.accounts(walletID: id) {
            try checkAuthentication(token)
            do {
                if let network = UTXONetwork(rawValue: account.networkID),
                   try await db.bitcoinState(accountID: account.id) == nil {
                    guard (0..<0x8000_0000).contains(account.accountIndex) else { throw StoreError.conflictingIdentity }
                    let descriptor = try OathWalletEngine.bitcoinDescriptor(for: secret,
                        account: UInt32(account.accountIndex), network: network)
                    try await db.prepareBitcoin(accountID: account.id, descriptor: descriptor)
                } else if account.networkID == "solana" {
                    _ = try await prepareSolanaReceive(account: account, secret: secret, database: db, token: token)
                }
            } catch {
                OathDiagnostics.record(error, component: "receive", operation: "prepare_wallet_addresses",
                                       context: ["chain": account.networkID])
                // Optional presentation preparation must not strand a committed
                // wallet. The Receive retry path can repair it locally later.
                try checkAuthentication(token)
            }
        }
        if let index = secret.passphraseIndex, secret.passphrase != nil {
            try await db.reconcileWalletFamilies([.init(id: id, parentID: secret.parentWalletID?.uuidString, index: index,
                                                        vaultReference: reference)])
        }
        let snapshot = try await db.snapshot(walletID: id, currency: Locale.autoupdatingCurrent.currency?.identifier ?? "USD")
        guard snapshot.wallet.vaultReference == reference else { throw OathWalletError.corruptVault }
        return try OathWalletProfile.stored(snapshot)
    }

    /// Repair public metadata after an interrupted two-store commit, then read
    /// the selected wallet from SQL, enrolling a missing chain when needed.
    private func restoredProfile(for contents: OathVaultContents, rootID: UUID,
                                 token: UUID) async throws -> OathWalletProfile {
        let db = try await database()
        let records = try await db.wallets(includingDeleted: true)
        for wallet in contents.wallets where !records.contains(where: { $0.id == wallet.id.uuidString }) {
            try checkAuthentication(token)
            _ = try await storedProfile(for: wallet, rootID: rootID, token: token)
        }
        try checkAuthentication(token)
        try await db.reconcileWalletLifecycle(contents.wallets.map {
            WalletLifecycle(id: $0.id.uuidString, deletedAt: $0.deletedAt?.timeIntervalSince1970)
        })
        try checkAuthentication(token)
        try await db.reconcileWalletFamilies(contents.walletFamilies(rootID: rootID))
        try checkAuthentication(token)
        // This is only a credential-anchor marker, never a wallet row. The
        // session resets a truly empty collection before opening Home. Retained
        // Recently Deleted material is still protected and never auto-erased.
        guard !contents.activeWallets.isEmpty else {
            return OathWalletProfile(id: rootID, addresses: [], createdAt: .distantPast, backedUp: true)
        }
        let activeIDs = Set(contents.activeWallets.map { $0.id.uuidString })
        let recordsInOrder = try await db.wallets().filter { activeIDs.contains($0.id) }
        let storedID = try await db.settings()["activeWalletID"]
        let selectedID = recordsInOrder.first(where: { $0.id == storedID })?.id ?? recordsInOrder.first?.id
        guard let selected = contents.activeWallets.first(where: { $0.id.uuidString == selectedID }) else {
            throw OathWalletError.corruptVault
        }
        // Persist a fallback selection too. A later reorder must not silently
        // switch the wallet on the next unlock after the active one was removed.
        try checkAuthentication(token)
        if storedID != selected.id.uuidString {
            try await db.setSetting("activeWalletID", value: selected.id.uuidString)
        }
        return try await storedProfile(for: selected, rootID: rootID, token: token)
    }

    func wallets(includingDeleted: Bool = false) async throws -> [WalletRecord] {
        guard let contents, let envelope, encryptionKey != nil else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let db = try await database()
        let records = try await db.wallets(includingDeleted: includingDeleted)
        try checkAuthentication(token)
        return Self.managedRecords(records, ids: Set(contents.wallets.map(\.id)), rootID: envelope.id)
    }

    func displayWallets() async throws -> [WalletRecord] {
        guard let data = try storage.read("vault-v1") else { return [] }
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        let db = try await database()
        let records = try await db.wallets()
        return Self.managedRecords(records, ids: Set(envelope.memberIDs), rootID: envelope.id)
    }

    private static func managedRecords(_ records: [WalletRecord], ids: Set<UUID>, rootID: UUID) -> [WalletRecord] {
        return records.filter {
            guard let id = UUID(uuidString: $0.id), ids.contains(id) else { return false }
            return $0.vaultReference == OathVaultContents.reference(for: id, rootID: rootID)
        }
    }

    /// One atomic ciphertext replacement preserves every wallet and the app's
    /// existing PIN/Face ID key. A stable request ID makes save retries safe.
    func addWallet(requestID: UUID, importing phrase: OathValidatedMnemonic?, privateKey: OathImportedPrivateKey? = nil, multisig: OathMultisigMaterial? = nil) async throws -> OathWalletProfile {
        guard phrase == nil || privateKey == nil else { throw OathWalletError.invalidPrivateKey }
        guard multisig == nil || (phrase == nil && privateKey == nil) else { throw OathWalletError.invalidPrivateKey }
        guard var contents, let key = encryptionKey, let envelope, profile != nil else { throw OathWalletError.locked }
        guard walletMutation == nil else { throw OathWalletError.unavailable }
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer {
            if walletMutation == mutation { walletMutation = nil }
        }
        let matches = contents.wallets.filter { wallet in
            wallet.id == requestID || (phrase != nil && wallet.mnemonic == phrase?.phrase && wallet.passphrase == nil && wallet.aezeed == phrase?.aezeed && wallet.electrum == phrase?.electrum)
                || (privateKey.map { wallet.privateKey?.hasSameIdentity(as: $0) == true } ?? false)
        }
        if let existing = matches.first(where: { $0.deletedAt == nil }) ?? matches.first {
            if let multisig {
                guard Self.sameRecoveryMaterial(existing, try multisig.secret(id: requestID)) else { throw OathWalletError.invalidPrivateKey }
            }
            return try await activateImportedWallet(existing, token: token)
        }
        var candidate = try multisig?.secret(id: requestID)
            ?? privateKey.map { try OathWalletEngine.imported($0, id: requestID) }
            ?? phrase.map { try OathWalletEngine.imported($0, id: requestID) }
            ?? OathWalletEngine.create(id: requestID)
        candidate.createdWithCustomization = true
        let derived = try OathWalletEngine.profile(for: candidate)
        contents.wallets.append(candidate)
        contents.reconcilePassphraseFamilies()
        let updated = try OathVaultEnvelope.seal(contents, rootID: envelope.id, key: key,
                                                salt: envelope.salt, iterations: envelope.iterations,
                                                protection: envelope.protection, biometricAccess: envelope.biometricAccess)
        try checkAuthentication(token)
        try storage.update(JSONEncoder().encode(updated), account: "vault-v1")
        self.contents = contents; self.envelope = updated
        // Cloud delivery starts after the local mutation finishes; it never
        // blocks activation, navigation or a subsequent wallet operation.
        return try await activateWallet(candidate, rootID: envelope.id, token: token, derived: derived)
    }

    /// A first restored wallet uses a new local app passcode. The iCloud
    /// password is never reused as the app PIN, written to disk or retained.
    func createRestoredWallet(digits: [UInt8], restoration: OathRestoredWallet) async throws {
        let token = authenticationGeneration
        _ = try await database()
        try checkAuthentication(token)
        guard try !exists() else { throw OathPasscodeSaveError.alreadyConfigured }
        var candidate = restoration.secret
        if candidate.passphrase != nil { candidate.passphraseIndex = 1 }
        let (sealed, key) = try OathVaultEnvelope.seal(candidate, digits: digits)
        try checkAuthentication(token)
        try storage.insert(JSONEncoder().encode(sealed), account: "vault-v1")
        let stored = try await storedProfile(for: candidate, rootID: candidate.id, derived: restoration.profile, token: token)
        try checkAuthentication(token)
        contents = OathVaultContents(wallets: [candidate], lifecycleVersion: !candidate.isMultisig && !candidate.isLocalMnemonic ? nil : 1)
        encryptionKey = key; envelope = sealed; profile = stored
    }

    /// Restoring into an unlocked app preserves its existing PIN, Face ID and
    /// every other wallet. UUID collisions never replace recovery material.
    func restoreWallet(_ restoration: OathRestoredWallet) async throws -> OathWalletProfile {
        try Task.checkCancellation()
        guard var contents, let key = encryptionKey, let envelope, profile != nil else { throw OathWalletError.locked }
        guard walletMutation == nil else { throw OathWalletError.unavailable }
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer {
            if walletMutation == mutation { walletMutation = nil }
        }
        var candidate = restoration.secret
        if let existing = contents.wallets.first(where: { $0.id == candidate.id }) {
            guard Self.sameRecoveryMaterial(existing, candidate),
                  Self.accountKeys(candidate).isSubset(of: Self.accountKeys(existing)) else { throw CloudBackupError.fileConflict }
            return try await activateImportedWallet(existing, token: token)
        }
        if let existing = contents.wallets.first(where: {
            Self.sameRecoveryMaterial($0, candidate) && Self.sameAccounts($0, candidate)
        }) {
            return try await activateImportedWallet(existing, token: token)
        }
        // Check SQL identity before the irreversible ciphertext replacement.
        // Normally every SQL wallet already appears in the encrypted index.
        let db = try await database()
        try checkAuthentication(token)
        guard try await db.wallet(candidate.id.uuidString) == nil else { throw CloudBackupError.fileConflict }
        try checkAuthentication(token)
        contents.wallets.append(candidate)
        contents.reconcilePassphraseFamilies()
        candidate = contents.wallets.last!
        let updated = try OathVaultEnvelope.seal(contents, rootID: envelope.id, key: key,
            salt: envelope.salt, iterations: envelope.iterations,
            protection: envelope.protection, biometricAccess: envelope.biometricAccess)
        try storage.update(JSONEncoder().encode(updated), account: "vault-v1")
        self.contents = contents; self.envelope = updated
        return try await activateWallet(candidate, rootID: envelope.id, token: token, derived: restoration.profile)
    }

    private static func sameRecoveryMaterial(_ lhs: OathWalletSecret, _ rhs: OathWalletSecret) -> Bool {
        let keysMatch: Bool
        switch (lhs.privateKey, rhs.privateKey) {
        case (nil, nil): keysMatch = true
        case (.some(let left), .some(let right)): keysMatch = left.hasSameIdentity(as: right)
        default: keysMatch = false
        }
        let multisigMatches = lhs.bitcoinMultisig.map { left in rhs.bitcoinMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.bitcoinMultisig == nil)
        let evmMatches = lhs.evmMultisig.map { left in rhs.evmMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.evmMultisig == nil)
        let tonMatches = lhs.tonMultisig.map { left in rhs.tonMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.tonMultisig == nil)
        let thorchainMatches = lhs.thorchainMultisig.map { left in rhs.thorchainMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.thorchainMultisig == nil)
        let nearMatches = lhs.nearMultisig.map { left in rhs.nearMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.nearMultisig == nil)
        let suiMatches = lhs.suiMultisig.map { left in rhs.suiMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.suiMultisig == nil)
        let aptosMatches = lhs.aptosMultisig.map { left in rhs.aptosMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.aptosMultisig == nil)
        let stellarMatches = lhs.stellarMultisig.map { left in rhs.stellarMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.stellarMultisig == nil)
        let xrplMatches = lhs.xrplMultisig.map { left in rhs.xrplMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.xrplMultisig == nil)
        let tronMatches = lhs.tronMultisig.map { left in rhs.tronMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.tronMultisig == nil)
        let solanaMatches = lhs.solanaMultisig.map { left in rhs.solanaMultisig.map { left.hasSameMaterial(as: $0) } ?? false } ?? (rhs.solanaMultisig == nil)
        return lhs.electrum == rhs.electrum && lhs.aezeed == rhs.aezeed && evmMatches && tonMatches && thorchainMatches && nearMatches && suiMatches && aptosMatches && solanaMatches && stellarMatches && xrplMatches && tronMatches && multisigMatches && lhs.mnemonic == rhs.mnemonic && lhs.language == rhs.language && lhs.passphrase == rhs.passphrase && keysMatch
    }

    private static func sameAccounts(_ lhs: OathWalletSecret, _ rhs: OathWalletSecret) -> Bool {
        return accountKeys(lhs) == accountKeys(rhs)
    }

    private static func accountKeys(_ secret: OathWalletSecret) -> Set<String> {
        if secret.electrum != nil { return ["bitcoin:0:electrum/0/0"] }
        if secret.aezeed != nil { return ["bitcoin:0:m/84'/0'/0'/0/0"] }
        if let m = secret.evmMultisig { return [m.network + ":0:evm-multisig-v1"] }
        if secret.tonMultisig != nil { return ["ton:0:ton-multisig-v1"] }
        if secret.thorchainMultisig != nil { return ["thorchain:0:thorchain-multisig-v1"] }
        if secret.nearMultisig != nil { return ["near:0:near-multisig-v1"] }
        if secret.suiMultisig != nil { return ["sui:0:sui-multisig-v1"] }
        if secret.aptosMultisig != nil { return ["aptos:0:aptos-multisig-v1"] }
        if secret.stellarMultisig != nil { return ["stellar:0:stellar-multisig-v1"] }
        if secret.xrplMultisig != nil { return ["xrpl:0:xrpl-multisig-v1"] }
        if secret.solanaMultisig != nil { return ["solana:0:solana-multisig-v1"] }
        if secret.tronMultisig != nil { return ["tron:0:tron-multisig-v1"] }
        if let multisig = secret.bitcoinMultisig { return ["\(multisig.chainID):0:\(multisig.accountPath)/0/0"] }
        let accounts = secret.restoration?.accounts ?? (secret.privateKey?.networks ?? OathImportChain.allCases).map {
            BackupWallet.Account(network: $0.id, derivationPath: secret.privateKey == nil ? $0.walletPath : "imported", index: 0)
        }
        return Set(accounts.map {
            // Both standard Solana paths belong to one recoverable account.
            // Changing the default must not duplicate or conflict with an old backup.
            let path = $0.network == "solana" && SolanaDerivation.matching(path: $0.derivationPath) != nil
                ? "solana-dual:\(SolanaDerivation.accountIndex(in: $0.derivationPath)!)" : $0.derivationPath
            return $0.network + ":" + String($0.index) + ":" + path
        })
    }

    func selectWallet(_ id: UUID) async throws -> OathWalletProfile {
        guard let contents, let envelope, encryptionKey != nil,
              let selected = contents.activeWallets.first(where: { $0.id == id }) else { throw OathWalletError.locked }
        guard walletMutation == nil else { throw OathWalletError.unavailable }
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer { if walletMutation == mutation { walletMutation = nil } }
        return try await activateWallet(selected, rootID: envelope.id, token: token)
    }

    /// The source contributes its original words, never its existing passphrase.
    /// A new immutable wallet is added; the source's keys and balances are untouched.
    /// There is no wallet-count limit. Keychain/SQL errors remain retryable.
    func addPassphraseWallet(sourceID: String, passphrase input: String, requestID: UUID) async throws -> OathWalletProfile {
        try Task.checkCancellation()
        let passphrase = try RecoveryPassphrase.normalized(input)
        guard let contents, let envelope, encryptionKey != nil, profile != nil else { throw OathWalletError.locked }
        guard walletMutation == nil else { throw OathWalletError.unavailable }
        guard let id = UUID(uuidString: sourceID),
              let source = contents.activeWallets.first(where: { $0.id == id }), !source.isLocalMnemonic, source.privateKey == nil, !source.isMultisig else {
            throw OathWalletError.unavailable
        }
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer {
            if walletMutation == mutation { walletMutation = nil }
        }
        if let previous = contents.wallets.first(where: { $0.id == requestID }) {
            guard previous.mnemonic == source.mnemonic, previous.passphrase == passphrase else {
                throw OathWalletError.unavailable
            }
            if previous.deletedAt != nil {
                return try await activateImportedWallet(previous, token: token)
            }
            return try await activateWallet(previous, rootID: envelope.id, token: token)
        }
        if let existing = contents.wallets.first(where: {
            $0.mnemonic == source.mnemonic && $0.passphrase.map { (try? RecoveryPassphrase.normalized($0)) == passphrase } == true
        }) {
            if existing.deletedAt != nil {
                return try await activateImportedWallet(existing, token: token)
            }
            throw OathWalletError.duplicatePassphraseWallet(existing.id)
        }

        let candidate = OathWalletSecret(id: requestID, mnemonic: source.mnemonic, language: source.language,
            createdAt: .now, backedUp: false, createdWithCustomization: true, passphrase: passphrase,
            parentWalletID: source.id,
            passphraseIndex: max(contents.lastPassphraseIndex ?? 0, contents.wallets.compactMap(\.passphraseIndex).max() ?? 0) + 1)
        let derivation = Task.detached(priority: .userInitiated) { try OathWalletEngine.profile(for: candidate) }
        let derived = try await withTaskCancellationHandler { try await derivation.value } onCancel: { derivation.cancel() }
        try checkAuthentication(token)
        guard var latest = self.contents, let key = encryptionKey, let current = self.envelope,
              current.id == envelope.id else { throw OathWalletError.locked }
        latest.wallets.append(candidate)
        latest.reconcilePassphraseFamilies()
        let updated = try OathVaultEnvelope.seal(latest, rootID: current.id, key: key,
            salt: current.salt, iterations: current.iterations, protection: current.protection,
            biometricAccess: current.biometricAccess)
        try checkAuthentication(token)
        try storage.update(JSONEncoder().encode(updated), account: "vault-v1")
        self.contents = latest; self.envelope = updated
        // Commit encrypted recovery material first. The ordinary unlock repair
        // reconstructs the public SQL row after interruption at this boundary.
        return try await activateWallet(candidate, rootID: current.id, token: token, derived: derived)
    }

    func canAddSeedPasswordWallet(sourceID: String) -> Bool {
        guard encryptionKey != nil, profile != nil, let contents,
              let source = contents.activeWallets.first(where: { $0.id.uuidString == sourceID }),
              let material = source.electrum, material.passphrase.isEmpty, !source.isDerivedWallet else { return false }
        return ElectrumMnemonic.allowsPassphrase(source.mnemonic)
    }

    /// Electrum extensions derive a different Bitcoin wallet. Aezeed encryption
    /// passwords deliberately cannot enter this derivation path.
    func addSeedPasswordWallet(sourceID: String, password: String, requestID: UUID) async throws -> OathWalletProfile {
        try Task.checkCancellation()
        guard password.utf8.count <= 4096, !ElectrumMnemonic.normalize(password).isEmpty else { throw OathWalletError.invalidPhrase }
        guard let contents, let envelope, encryptionKey != nil, profile != nil else { throw OathWalletError.locked }
        guard walletMutation == nil, canAddSeedPasswordWallet(sourceID: sourceID),
              let source = contents.activeWallets.first(where: { $0.id.uuidString == sourceID }) else { throw OathWalletError.unavailable }
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer { if walletMutation == mutation { walletMutation = nil } }
        let work = Task.detached(priority: .userInitiated) {
            try ElectrumMnemonic.decode(source.mnemonic, passphrase: password)
        }
        let material = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try checkAuthentication(token)
        if let previous = contents.wallets.first(where: { $0.id == requestID }) {
            guard previous.mnemonic == source.mnemonic, previous.electrum == material,
                  previous.deletedAt == nil else { throw OathWalletError.unavailable }
            return try await activateWallet(previous, rootID: envelope.id, token: token)
        }
        if let duplicate = contents.wallets.first(where: {
            $0.mnemonic == source.mnemonic && $0.electrum?.kind == material.kind && $0.electrum?.seed == material.seed
                && $0.electrum?.secondSeed == material.secondSeed
        }) { throw OathWalletError.duplicatePassphraseWallet(duplicate.id) }
        let candidate = OathWalletSecret(id: requestID, mnemonic: source.mnemonic, language: "electrum",
            createdAt: .now, backedUp: false, electrum: material,
            createdWithCustomization: true, parentWalletID: source.id,
            passphraseIndex: max(contents.lastPassphraseIndex ?? 0, contents.wallets.compactMap(\.passphraseIndex).max() ?? 0) + 1)
        let derivation = Task.detached(priority: .userInitiated) { try OathWalletEngine.profile(for: candidate) }
        let derived = try await withTaskCancellationHandler { try await derivation.value } onCancel: { derivation.cancel() }
        try checkAuthentication(token)
        guard var latest = self.contents, let key = encryptionKey, let current = self.envelope,
              current.id == envelope.id else { throw OathWalletError.locked }
        latest.wallets.append(candidate)
        latest.reconcilePassphraseFamilies()
        let updated = try OathVaultEnvelope.seal(latest, rootID: current.id, key: key,
            salt: current.salt, iterations: current.iterations, protection: current.protection,
            biometricAccess: current.biometricAccess)
        try checkAuthentication(token)
        try storage.update(JSONEncoder().encode(updated), account: "vault-v1")
        self.contents = latest; self.envelope = updated
        return try await activateWallet(candidate, rootID: current.id, token: token, derived: derived)
    }

    /// Importing recovery material explicitly restores a matching retained
    /// wallet. Ordinary selection still rejects deleted wallets. Persist the
    /// encrypted lifecycle first so unlock can repair an interrupted SQL write.
    private func activateImportedWallet(_ selected: OathWalletSecret, token: UUID) async throws -> OathWalletProfile {
        guard var contents, let key = encryptionKey, let sealed = envelope,
              let index = contents.wallets.firstIndex(where: { $0.id == selected.id })
        else { throw OathWalletError.locked }
        if contents.wallets[index].deletedAt != nil {
            contents.wallets[index].deletedAt = nil
            _ = try persistLifecycle(contents, sealed: sealed, key: key, token: token)
        }
        // Also repair a previous import whose vault commit succeeded but SQL
        // reconciliation was interrupted, including missing public metadata.
        _ = try await restoredProfile(for: contents, rootID: sealed.id, token: token)
        try checkAuthentication(token)
        return try await activateWallet(contents.wallets[index], rootID: sealed.id, token: token)
    }

    private func activateWallet(_ selected: OathWalletSecret, rootID: UUID, token: UUID,
                                derived: OathWalletProfile? = nil) async throws -> OathWalletProfile {
        guard selected.deletedAt == nil else { throw OathWalletError.unavailable }
        let updated = try await storedProfile(for: selected, rootID: rootID, derived: derived, token: token)
        try checkAuthentication(token)
        let db = try await database()
        try checkAuthentication(token)
        if let contents { try await db.reconcileWalletFamilies(contents.walletFamilies(rootID: rootID)) }
        try checkAuthentication(token)
        try await db.setSetting("activeWalletID", value: selected.id.uuidString)
        try checkAuthentication(token)
        profile = updated
        return updated
    }

    private func checkAuthentication(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == authenticationGeneration, !resetting else { throw CancellationError() }
    }

    func reloadProfile() async throws -> OathWalletProfile {
        guard let secret, let envelope, encryptionKey != nil else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let updated = try await storedProfile(for: secret, rootID: envelope.id, token: token)
        guard token == authenticationGeneration, profile?.id == secret.id else { throw CancellationError() }
        profile = updated
        return updated
    }

    func recoveryWords() throws -> [String] {
        guard let secret else { throw OathWalletError.locked }
        guard secret.privateKey == nil, !secret.isMultisig else { throw OathWalletError.unavailable }
        return OathMnemonicValidator.words(in: secret.mnemonic)
    }

    /// Fresh authorization is scoped to this export. Never select a different
    /// wallet, unlock the app, derive accounts or start any network work here.
    func recoveryWords(walletID: String, digits: [UInt8]) throws -> [String] {
        try recoveryMaterial(walletID: walletID, digits: digits).words
    }

    func recoveryWordsWithBiometrics(walletID: String, reason: String) async throws -> [String] {
        try await recoveryMaterialWithBiometrics(walletID: walletID, reason: reason).words
    }

    func recoveryMaterial(walletID: String, digits: [UInt8]) throws -> OathRecoveryMaterial {
        let id = try recoveryWalletID(walletID)
        let (_, _, opened) = try openWithPasscode(digits, now: .now)
        return try material(in: opened, walletID: id)
    }

    func recoveryMaterialWithBiometrics(walletID: String, reason: String) async throws -> OathRecoveryMaterial {
        let id = try recoveryWalletID(walletID)
        let token = authenticationGeneration
        let (_, _, opened) = try await openWithBiometrics(reason: reason)
        try checkAuthentication(token)
        _ = try recoveryWalletID(walletID)
        return try material(in: opened, walletID: id)
    }

    private func recoveryWalletID(_ value: String) throws -> UUID {
        try Task.checkCancellation()
        guard encryptionKey != nil, profile != nil, let contents else { throw OathWalletError.locked }
        guard let id = UUID(uuidString: value), contents.activeWallets.contains(where: { $0.id == id }) else {
            throw OathWalletError.unavailable
        }
        return id
    }

    private func material(in opened: OathVaultContents, walletID: UUID) throws -> OathRecoveryMaterial {
        try Task.checkCancellation()
        guard let wallet = opened.activeWallets.first(where: { $0.id == walletID }) else {
            throw OathWalletError.unavailable
        }
        guard wallet.privateKey == nil else { throw OathWalletError.unavailable }
        return .init(words: OathMnemonicValidator.words(in: wallet.mnemonic), passphrase: wallet.electrum?.passphrase.isEmpty == false ? wallet.electrum?.passphrase : wallet.aezeed?.passphrase.isEmpty == false ? wallet.aezeed?.passphrase : wallet.passphrase, multisig: wallet.bitcoinMultisig, evmMultisig: wallet.evmMultisig, tonMultisig: wallet.tonMultisig, thorchainMultisig: wallet.thorchainMultisig, nearMultisig: wallet.nearMultisig, suiMultisig: wallet.suiMultisig, aptosMultisig: wallet.aptosMultisig, stellarMultisig: wallet.stellarMultisig, xrplMultisig: wallet.xrplMultisig, tronMultisig: wallet.tronMultisig, solanaMultisig: wallet.solanaMultisig)
    }

    func privateKeyAccounts(walletID: String) async throws -> [OathPrivateKeyAccount] {
        let id = try recoveryWalletID(walletID), token = authenticationGeneration
        guard let envelope else { throw OathWalletError.locked }
        let db = try await database()
        let wallet = try await db.wallet(walletID)
        guard wallet?.vaultReference == OathVaultContents.reference(for: id, rootID: envelope.id) else {
            throw OathWalletError.corruptVault
        }
        let snapshot = try await db.snapshot(walletID: walletID, currency: "USD")
        try checkAuthentication(token)
        let order = PortfolioAssetOrder(snapshot.holdings)
        let accounts = AssetOrdering.sorted(snapshot.accounts) {
            order.key(networkID: $0.networkID, accountID: $0.id,
                      name: OathImportChain(rawValue: $0.networkID)?.name ?? $0.networkID)
        }
        guard let secret = contents?.activeWallets.first(where: { $0.id == id }) else { throw OathWalletError.locked }
        var result: [OathPrivateKeyAccount] = []
        for account in accounts {
            guard let chain = OathImportChain(rawValue: account.networkID) else { continue }
            if chain == .solana {
                let state = try await prepareSolanaReceive(account: account, secret: secret, database: db, token: token)
                result += state.addresses.map {
                    .init(id: $0.path == account.derivationPath ? account.id : account.id + ":" + $0.path,
                          chain: chain, address: $0.address, path: $0.path)
                }
            } else {
                result.append(.init(id: account.id, chain: chain, address: account.address, path: account.derivationPath))
            }
        }
        return result
    }

    func privateKeyBranches(walletID: String, accountID: String) async throws -> [BitcoinBranch] {
        let (_, state, _) = try await privateKeyBitcoinContext(walletID: walletID, accountID: accountID)
        return state.descriptor.branches
    }

    func privateKeyAddresses(walletID: String, accountID: String, branchID: String,
                             after: UInt32?, search: BitcoinAddressSearch = .init()) async throws -> [OathPrivateKeyAccount] {
        let token = authenticationGeneration
        let (account, state, db) = try await privateKeyBitcoinContext(walletID: walletID, accountID: accountID)
        guard state.descriptor.branches.contains(where: { $0.id == branchID }) else { throw OathWalletError.unavailable }
        let addresses = try await db.bitcoinAddresses(accountID: accountID, branchID: branchID, after: after, search: search)
        try checkAuthentication(token)
        return try addresses.map { try privateKeyAddressAccount(account, address: $0) }
    }

    private func privateKeyBitcoinContext(walletID: String, accountID: String) async throws -> (AccountRecord, BitcoinAccountState, OathDatabase) {
        let token = authenticationGeneration, id = try recoveryWalletID(walletID)
        // Validate the requested wallet even when it is not the active wallet.
        guard try await privateKeyAccounts(walletID: walletID).contains(where: { $0.id == accountID }),
              let secret = contents?.activeWallets.first(where: { $0.id == id }) else { throw OathWalletError.unavailable }
        let db = try await database()
        guard let account = try await db.accounts(walletID: walletID).first(where: { $0.id == accountID }),
              let network = UTXONetwork(rawValue: account.networkID),
              account.accountIndex >= 0, account.accountIndex < 0x8000_0000 else { throw OathWalletError.unavailable }
        try checkAuthentication(token)
        if try await db.bitcoinState(accountID: accountID) == nil {
            let descriptor = try OathWalletEngine.bitcoinDescriptor(for: secret, account: UInt32(account.accountIndex), network: network)
            try checkAuthentication(token)
            try await db.prepareBitcoin(accountID: accountID, descriptor: descriptor)
        }
        guard let state = try await db.bitcoinState(accountID: accountID), state.descriptor.network == network else { throw OathWalletError.unavailable }
        try checkAuthentication(token)
        return (account, state, db)
    }

    private func privateKeyAddressAccount(_ account: AccountRecord, address: BitcoinDerivedAddress) throws -> OathPrivateKeyAccount {
        guard let chain = OathImportChain(rawValue: account.networkID),
              account.accountIndex >= 0, account.accountIndex < 0x8000_0000 else { throw OathWalletError.unavailable }
        return .init(id: account.id + "|utxo|" + address.id, chain: chain, address: address.address, path: address.path,
                     utxo: .init(accountID: account.id, accountIndex: UInt32(account.accountIndex), address: address))
    }

    func privateKey(walletID: String, accountID: String, digits: [UInt8]) async throws -> OathPrivateKeyExport {
        let token = authenticationGeneration
        let account = try await privateKeyAccount(walletID: walletID, accountID: accountID)
        try checkAuthentication(token)
        let (_, _, opened) = try openWithPasscode(digits, now: .now)
        return try exportPrivateKey(in: opened, walletID: walletID, account: account)
    }

    func privateKeyWithBiometrics(walletID: String, accountID: String, reason: String) async throws -> OathPrivateKeyExport {
        let token = authenticationGeneration
        let account = try await privateKeyAccount(walletID: walletID, accountID: accountID)
        try checkAuthentication(token)
        let (_, _, opened) = try await openWithBiometrics(reason: reason)
        try checkAuthentication(token)
        return try exportPrivateKey(in: opened, walletID: walletID, account: account)
    }

    private func privateKeyAccount(walletID: String, accountID: String) async throws -> OathPrivateKeyAccount {
        let parts = accountID.components(separatedBy: "|utxo|")
        if parts.count == 2 {
            let origin = parts[1].split(separator: ":")
            guard origin.count == 3, let index = UInt32(origin[2]) else { throw OathWalletError.unavailable }
            let branchID = String(origin[0]) + ":" + String(origin[1])
            let token = authenticationGeneration
            let (account, state, db) = try await privateKeyBitcoinContext(walletID: walletID, accountID: parts[0])
            guard state.descriptor.branches.contains(where: { $0.id == branchID }),
                  let address = try await db.bitcoinAddress(accountID: account.id, branchID: branchID, index: index) else {
                throw OathWalletError.unavailable
            }
            try checkAuthentication(token)
            let result = try privateKeyAddressAccount(account, address: address)
            guard result.id == accountID else { throw OathWalletError.unavailable }
            return result
        }
        guard let account = try await privateKeyAccounts(walletID: walletID).first(where: { $0.id == accountID }) else {
            throw OathWalletError.unavailable
        }
        return account
    }

    private func exportPrivateKey(in opened: OathVaultContents, walletID: String,
                                  account: OathPrivateKeyAccount) throws -> OathPrivateKeyExport {
        let id = try recoveryWalletID(walletID)
        guard let wallet = opened.wallets.first(where: { $0.id == id }) else { throw OathWalletError.unavailable }
        // This actor is not MainActor. Derive exactly one persisted account,
        // check its address, and never save/export unrelated wallet secrets.
        let result = try OathWalletEngine.privateKey(for: wallet, account: account)
        try Task.checkCancellation()
        return result
    }

    func markBackedUp() async throws -> OathWalletProfile {
        guard let secret, let envelope, encryptionKey != nil else { throw OathWalletError.locked }
        let token = authenticationGeneration
        let db = try await database()
        try await db.markBackedUp(secret.id.uuidString)
        let updated = try await storedProfile(for: secret, rootID: envelope.id, token: token)
        guard token == authenticationGeneration, profile?.id == secret.id else { throw CancellationError() }
        profile = updated
        return updated
    }

    func securityState() async throws -> OathWalletSecurityState {
        guard let data = try storage.read("vault-v1") else { return .init() }
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        guard sealed.passcodeEnabled else {
            _ = try sealed.deviceKey() // Reject malformed disabled records.
            return .init(passcodeEnabled: false, biometricsEnabled: false)
        }
        // Enrollment metadata is optional. A temporarily unavailable biometric
        // item must never prevent the passcode screen from opening.
        let enrolled = sealed.biometricAccess != false ? (await OathDiagnostics.attempt("hasEnrollment", body: { try await biometricStore.hasEnrollment() })) ?? false : false
        return .init(passcodeEnabled: true, biometricsEnabled: enrolled)
    }

    func unlockWithoutPasscode() async throws -> OathWalletProfile {
        var stage = "unlock"
        return try await unlockWithoutPasscode(stage: &stage)
    }

    /// Return the precise failing step to the startup boundary, which owns
    /// protected-data deferral and reports the original error once.
    func unlockWithoutPasscode(stage: inout String) async throws -> OathWalletProfile {
        let token = authenticationGeneration
        stage = "keychain_read"
        guard let data = try storage.read("vault-v1") else { throw OathWalletError.unavailable }
        stage = "envelope_decode"
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        stage = "device_key"
        let key = try sealed.deviceKey()
        stage = "vault_open"
        let opened = try sealed.openContents(using: key)
        stage = "wallet_reconcile"
        let (current, recovered, restored) = try await reconcileUnlocked(sealed: sealed, key: key, opened: opened, token: token)
        try checkAuthentication(token)
        contents = recovered; encryptionKey = key; envelope = current; profile = restored
        return restored
    }

    /// Freshly verifies entry to Security without granting permission to change
    /// credentials. Each sensitive change keeps its own existing authorization.
    func authenticateSecurityAccess(digits: [UInt8]? = nil, reason: String) async throws {
        guard !resetting, encryptionKey != nil, profile != nil, walletMutation == nil,
              let envelope else { throw OathWalletError.locked }
        let token = authenticationGeneration
        if envelope.passcodeEnabled {
            if let digits { _ = try openWithPasscode(digits, now: .now) }
            else { _ = try await openWithBiometrics(reason: reason) }
        }
        try checkAuthentication(token)
    }

    func authorizeSecurityChange(digits: [UInt8]) throws -> UUID {
        guard encryptionKey != nil, profile != nil, walletMutation == nil else { throw OathWalletError.locked }
        _ = try openWithPasscode(digits, now: .now)
        let id = UUID()
        securityAuthorization = (id, ContinuousClock.now.advanced(by: .seconds(120)))
        return id
    }

    func cancelSecurityAuthorization(_ id: UUID) {
        if securityAuthorization?.id == id { securityAuthorization = nil }
    }

    private func checkSecurityAuthorization(_ id: UUID?) throws {
        guard let id, let authorization = securityAuthorization, authorization.id == id,
              ContinuousClock.now <= authorization.deadline else { throw OathWalletError.locked }
    }

    func setPasscode(_ digits: [UInt8]?, authorization: UUID?) async throws {
        guard let contents, let encryptionKey, let envelope, profile != nil,
              walletMutation == nil else { throw OathWalletError.locked }
        if envelope.passcodeEnabled { try checkSecurityAuthorization(authorization) }
        let (updated, key) = try envelope.replacingPasscode(digits, contents: contents, currentKey: encryptionKey)
        try Task.checkCancellation()
        try storage.update(JSONEncoder().encode(updated), account: "vault-v1")
        self.envelope = updated; self.encryptionKey = key
        permissionAuthorization = nil
        securityAuthorization = nil
        biometricEnrollment = nil
        resetAuthorization = nil
        removalAuthorization = nil
        // The disabled flag and rotated key already revoke the old credential
        // atomically. A failed OS cleanup cannot accidentally re-enable Face ID.
        if !updated.passcodeEnabled { await OathDiagnostics.attempt("disable_biometrics") { try await biometricStore.disable() } }
    }

    func disableBiometrics() async throws {
        try setBiometricAccess(false)
        // A late enrollment reply must not undo the user's newer choice.
        biometricEnrollment = nil
        permissionAuthorization = nil
        securityAuthorization = nil
        try await biometricStore.disable()
    }

    /// Enrolling from an unlocked vault requires a fresh system biometric match,
    /// not another PIN entry. A separate operation identity prevents late OS
    /// replies from reversing a disable, lock, passcode change or cancellation.
    func enableBiometrics(strings: OathLocalizer) async throws -> OathBiometricSetupResult {
        try Task.checkCancellation()
        guard !resetting, biometricEnrollment == nil else { throw OathWalletError.locked }
        let token = authenticationGeneration
        try setBiometricAccess(false)
        let enrollment = UUID()
        biometricEnrollment = enrollment
        defer { if biometricEnrollment == enrollment { biometricEnrollment = nil } }
        let result = await biometricStore.enableIfAvailable(strings: strings,
            credentialProvider: { try await self.biometricEnrollmentCredential(enrollment, authentication: token) })
        try checkAuthentication(token)
        guard biometricEnrollment == enrollment else { throw OathWalletError.locked }
        if case .enabled = result { try setBiometricAccess(true) }
        return result
    }

    private func biometricEnrollmentCredential(_ enrollment: UUID, authentication: UUID) throws -> Data {
        try checkAuthentication(authentication)
        guard biometricEnrollment == enrollment else { throw OathWalletError.locked }
        return try biometricCredential()
    }

    private func setBiometricAccess(_ enabled: Bool) throws {
        guard var envelope, envelope.passcodeEnabled, encryptionKey != nil, profile != nil,
              walletMutation == nil else { throw OathWalletError.locked }
        envelope.biometricAccess = enabled
        try storage.update(JSONEncoder().encode(envelope), account: "vault-v1")
        self.envelope = envelope
        permissionAuthorization = nil
        resetAuthorization = nil
        removalAuthorization = nil
    }

    private struct BiometricKey: Codable { let walletID: UUID; var key: Data }

    func biometricCredential() throws -> Data {
        guard let envelope, envelope.passcodeEnabled, let encryptionKey else { throw OathWalletError.locked }
        return try JSONEncoder().encode(BiometricKey(walletID: envelope.id, key: encryptionKey.withUnsafeBytes { Data($0) }))
    }

    func unlockWithBiometrics(reason: String) async throws -> OathWalletProfile {
        try Task.checkCancellation()
        let token = UUID()
        authenticationGeneration = token
        let (sealed, key, opened) = try await openWithBiometrics(reason: reason)
        let (current, recovered, derived) = try await reconcileUnlocked(sealed: sealed, key: key, opened: opened, token: token)
        try checkAuthentication(token)
        contents = recovered; encryptionKey = key; envelope = current; profile = derived
        return derived
    }

    private func openWithBiometrics(reason: String) async throws
        -> (OathVaultEnvelope, SymmetricKey, OathVaultContents) {
        guard !resetting else { throw OathWalletError.locked }
        let token = authenticationGeneration
        try Task.checkCancellation()
        let current: OathVaultEnvelope
        if encryptionKey != nil, let envelope, envelope.passcodeEnabled, envelope.biometricAccess != false {
            // An unlocked operation already has an authenticated envelope.
            // Prompt first instead of queueing another Keychain read ahead of
            // Face ID. The stored envelope and released credential are still
            // checked together below before any sensitive operation proceeds.
            current = envelope
        } else {
            guard let data = try storage.read("vault-v1") else { throw OathWalletError.unavailable }
            current = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        }
        if !current.passcodeEnabled {
            let key = try current.deviceKey()
            return (current, key, try current.openContents(using: key))
        }
        guard current.biometricAccess != false else { throw OathBiometricCredentialError.missing }
        var credentialData = try await biometricStore.read(reason: reason)
        defer { credentialData.resetBytes(in: credentialData.startIndex..<credentialData.endIndex) }
        try Task.checkCancellation()
        guard token == authenticationGeneration else { throw CancellationError() }
        guard let stored = try storage.read("vault-v1") else { throw OathWalletError.unavailable }
        guard var credential = OathDiagnostics.attempt("decode_biometric_credential", body: { try JSONDecoder().decode(BiometricKey.self, from: credentialData) }) else {
            throw OathBiometricCredentialError.invalid
        }
        defer { credential.key.resetBytes(in: credential.key.startIndex..<credential.key.endIndex) }
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: stored)
        guard sealed.passcodeEnabled, sealed.biometricAccess != false else { throw OathBiometricCredentialError.missing }
        guard credential.walletID == sealed.id, credential.key.count == 32 else {
            throw OathBiometricCredentialError.invalid
        }
        let key = SymmetricKey(data: credential.key)
        let opened: OathVaultContents
        do { opened = try sealed.openContents(using: key) }
        catch OathWalletError.wrongPasscode { OathDiagnostics.record(OathWalletError.wrongPasscode, operation: "open_biometric_credential"); throw OathBiometricCredentialError.invalid }
        let hasAttempts = try storage.read("unlock-attempts-v1") != nil
        try saveAttempts(.init(), existing: hasAttempts)
        try checkAuthentication(token)
        return (sealed, key, opened)
    }

    private func saveAttempts(_ attempts: OathUnlockAttempts, existing: Bool) throws {
        let data = try JSONEncoder().encode(attempts)
        if existing { try storage.update(data, account: "unlock-attempts-v1") }
        else { try storage.insert(data, account: "unlock-attempts-v1") }
    }

    /// The root ID is an installation credential anchor in v9, independent of
    /// wallet membership. Even deleting its original wallet preserves Face ID.
    private func reconcileUnlocked(sealed: OathVaultEnvelope, key: SymmetricKey,
                                   opened: OathVaultContents, token: UUID, now: Date = .now)
        async throws -> (OathVaultEnvelope, OathVaultContents, OathWalletProfile) {
        var current = sealed, recovered = opened
        let expired = Set(recovered.wallets.filter {
            $0.deletedAt.map { now.timeIntervalSince($0) >= OathVaultContents.retention } == true
        }.map(\.id))
        if !expired.isEmpty {
            recovered.lifecycleVersion = 1
            recovered.wallets.removeAll { expired.contains($0.id) }
            recovered.purgedWalletIDs = Array(Set(recovered.purgedWalletIDs ?? []).union(expired)).sorted { $0.uuidString < $1.uuidString }
            current = try persistLifecycle(recovered, sealed: current, key: key, token: token)
        }
        let db = try await database()
        if let batch = recovered.legacyUpgrade {
            try checkAuthentication(token)
            try await db.commitLegacyUpgrade(batch)
            // SQL now owns subsequent edits. Retaining the initial batch could
            // recreate removed public records after future database recovery.
            recovered.legacyUpgrade = nil
            current = try persistLifecycle(recovered, sealed: current, key: key, token: token)
        }
        for id in recovered.purgedWalletIDs ?? [] {
            try checkAuthentication(token)
            try checkAuthentication(token)
            try await db.deleteWalletMetadata(id.uuidString)
        }
        try checkAuthentication(token)
        if recovered.purgedWalletIDs?.isEmpty == false {
            recovered.purgedWalletIDs = nil
            current = try persistLifecycle(recovered, sealed: current, key: key, token: token)
        }
        let familyRecords = try await db.wallets(includingDeleted: true)
        try checkAuthentication(token)
        if recovered.reconcilePassphraseFamilies(records: familyRecords) {
            current = try persistLifecycle(recovered, sealed: current, key: key, token: token)
        }
        let selected = try await restoredProfile(for: recovered, rootID: current.id, token: token)
        try checkAuthentication(token)
        return (current, recovered, selected)
    }

    private func persistLifecycle(_ updated: OathVaultContents, sealed: OathVaultEnvelope,
                                  key: SymmetricKey, token: UUID) throws -> OathVaultEnvelope {
        try checkAuthentication(token)
        let replacement = try OathVaultEnvelope.seal(updated, rootID: sealed.id, key: key,
            salt: sealed.salt, iterations: sealed.iterations, protection: sealed.protection,
            biometricAccess: sealed.biometricAccess)
        try storage.update(JSONEncoder().encode(replacement), account: "vault-v1")
        // Publish every durable commit before any SQL await. An interrupted
        // reconciliation must never let another writer resurrect erased keys.
        if encryptionKey != nil { self.contents = updated; self.envelope = replacement }
        return replacement
    }

    private func validateRemoval(_ action: OathWalletRemovalAction) throws {
        guard let contents, !action.ids.isEmpty else { throw OathWalletError.unavailable }
        let active = Set(contents.activeWallets.map { $0.id.uuidString })
        if action.resetsApp {
            guard !action.permanently, !active.isEmpty, action.ids == active,
                  action.recentlyDeletedIDs == Set(contents.wallets.filter { $0.deletedAt != nil }.map { $0.id.uuidString })
            else { throw OathWalletError.unavailable }
            return
        }
        guard action.recentlyDeletedIDs.isEmpty,
              // Final removal needs the explicit permanent-reset confirmation.
              action.permanently || !active.subtracting(action.ids).isEmpty,
              action.ids.allSatisfy({ id in contents.wallets.contains {
                  $0.id.uuidString == id && ($0.deletedAt != nil) == action.permanently
              } }) else { throw OathWalletError.unavailable }
    }

    func authorizeWalletRemoval(_ action: OathWalletRemovalAction, digits: [UInt8]? = nil,
                                reason: String, now: ContinuousClock.Instant = .now) async throws -> UUID {
        guard !resetting, encryptionKey != nil, profile != nil, walletMutation == nil,
              let envelope else { throw OathWalletError.locked }
        try validateRemoval(action)
        let token = authenticationGeneration
        if envelope.passcodeEnabled {
            if let digits { _ = try openWithPasscode(digits, now: .now) }
            else { _ = try await openWithBiometrics(reason: reason) }
        }
        try checkAuthentication(token)
        try validateRemoval(action)
        let id = UUID()
        removalAuthorization = (id, action, now.advanced(by: .seconds(120)))
        return id
    }

    func cancelWalletRemovalAuthorization(_ id: UUID) {
        if removalAuthorization?.id == id { removalAuthorization = nil }
    }

    func removeWallets(_ action: OathWalletRemovalAction, authorization: UUID,
                       now: Date = .now, clock: ContinuousClock.Instant = .now) async throws -> OathWalletProfile {
        guard !action.resetsApp, walletMutation == nil, let grant = removalAuthorization, grant.id == authorization,
              grant.action == action, clock <= grant.deadline, now.timeIntervalSince1970.isFinite,
              let contents, let key = encryptionKey, let sealed = envelope else { throw OathWalletError.locked }
        try validateRemoval(action)
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer { if walletMutation == mutation { walletMutation = nil } }
        let db = try await database()
        try await db.validateWalletRemoval(action.ids)
        try checkAuthentication(token)
        removalAuthorization = nil // Consume once, before the atomic mutation.
        var updated = contents
        updated.lifecycleVersion = 1
        if action.permanently {
            let ids = Set(action.ids.compactMap(UUID.init(uuidString:)))
            updated.wallets.removeAll { ids.contains($0.id) }
            updated.purgedWalletIDs = Array(Set(updated.purgedWalletIDs ?? []).union(ids)).sorted { $0.uuidString < $1.uuidString }
        } else {
            // Round up to an exactly representable second. Date's reference
            // epoch and SQLite's Unix epoch must agree on the deadline, and
            // conversion must never shorten seven full days of retention.
            let removedAt = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970))
            for index in updated.wallets.indices where action.ids.contains(updated.wallets[index].id.uuidString) {
                updated.wallets[index].deletedAt = removedAt
            }
        }
        let committed = try persistLifecycle(updated, sealed: sealed, key: key, token: token)
        self.contents = updated; self.envelope = committed
        let (current, recovered, selected) = try await reconcileUnlocked(sealed: committed, key: key, opened: updated, token: token, now: now)
        self.contents = recovered; self.envelope = current; self.profile = selected
        return selected
    }

    func recoverDeletedWallets(_ ids: Set<String>, now: Date = .now) async throws -> OathWalletProfile {
        guard walletMutation == nil, var contents, let key = encryptionKey, let sealed = envelope,
              !ids.isEmpty, now.timeIntervalSince1970.isFinite,
              ids.allSatisfy({ id in contents.wallets.contains {
                  $0.id.uuidString == id && $0.deletedAt.map { now.timeIntervalSince($0) < OathVaultContents.retention } == true
              } }) else { throw OathWalletError.unavailable }
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer { if walletMutation == mutation { walletMutation = nil } }
        for index in contents.wallets.indices where ids.contains(contents.wallets[index].id.uuidString) {
            contents.wallets[index].deletedAt = nil
        }
        let committed = try persistLifecycle(contents, sealed: sealed, key: key, token: token)
        self.contents = contents; self.envelope = committed
        let (current, recovered, selected) = try await reconcileUnlocked(sealed: committed, key: key, opened: contents, token: token, now: now)
        self.contents = recovered; self.envelope = current; self.profile = selected
        return selected
    }

    func maintainDeletedWallets(now: Date = .now) async throws -> OathWalletProfile {
        guard walletMutation == nil, let key = encryptionKey,
              let data = try storage.read("vault-v1") else { throw OathWalletError.locked }
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        let contents = try sealed.openContents(using: key)
        let mutation = UUID(), token = authenticationGeneration
        walletMutation = mutation
        defer { if walletMutation == mutation { walletMutation = nil } }
        let (current, recovered, selected) = try await reconcileUnlocked(sealed: sealed, key: key, opened: contents, token: token, now: now)
        self.contents = recovered; self.envelope = current; self.profile = selected
        return selected
    }

    /// Fresh authorization only creates an expiring capability. No data is
    /// touched until the separate warning screen has been confirmed.
    func authorizeReset(digits: [UInt8]? = nil, reason: String,
                        now: ContinuousClock.Instant = .now) async throws -> UUID {
        guard !resetting, encryptionKey != nil, profile != nil, walletMutation == nil,
              let envelope else { throw OathWalletError.locked }
        let token = authenticationGeneration
        if envelope.passcodeEnabled {
            if let digits { _ = try openWithPasscode(digits, now: .now) }
            else { _ = try await openWithBiometrics(reason: reason) }
        }
        try checkAuthentication(token)
        let id = UUID()
        resetAuthorization = (id, now.advanced(by: .seconds(120)))
        return id
    }

    func cancelResetAuthorization(_ id: UUID) {
        if resetAuthorization?.id == id { resetAuthorization = nil }
    }

    /// Last-wallet deletion uses the same durable reset journal as Reset App.
    /// A normal soft-delete grant cannot authorize this, nor can a grant whose
    /// active/recently-deleted membership changed after the two confirmations.
    func beginReset(removing action: OathWalletRemovalAction, authorization: UUID,
                    now: ContinuousClock.Instant = .now) async throws {
        guard action.resetsApp, let grant = removalAuthorization,
              grant.id == authorization, grant.action == action, now <= grant.deadline,
              !resetting, walletMutation == nil, encryptionKey != nil, profile != nil
        else { throw OathWalletError.locked }
        try validateRemoval(action)
        removalAuthorization = nil
        resetAuthorization = (authorization, grant.deadline)
        try await beginReset(authorization: authorization, now: now)
    }

    /// The failed-upgrade screen is the only caller. Unlike normal reset this
    /// cannot require the new PIN, because no usable new vault may exist yet.
    func beginFailedLegacyReset(source: LegacyWalletSnapshot) async throws {
        guard !resetting, !legacyMigrationInProgress, walletMutation == nil,
              let failedLegacyUpgradeFingerprint,
              failedLegacyUpgradeFingerprint == (try source.fingerprint) else { throw OathWalletError.locked }
        resetting = true
        lock()
        do {
            let db = try await database()
            _ = try await db.beginWalletReset(legacyRecovery: true)
            self.failedLegacyUpgradeFingerprint = nil
        } catch {
            OathDiagnostics.record(error, component: "legacy_upgrade", operation: "begin_reset", context: ["stage": "journal"])
            resetting = false
            throw error // No destructive work starts until the intent is durable.
        }
    }

    func hasPendingLegacyRecoveryReset() async throws -> Bool {
        try await database().pendingLegacyRecoveryReset()
    }

    func hasPendingEmptyWalletReset() async throws -> Bool {
        try await database().pendingEmptyWalletReset() != nil
    }

    /// Only authenticated encrypted membership can authorize automatic cleanup.
    /// A missing SQL row, locked vault, failed load, or retained deleted wallet
    /// must never be interpreted as an empty wallet installation.
    func beginEmptyWalletResetIfNeeded() async throws -> Bool {
        guard !resetting, !legacyMigrationInProgress, walletMutation == nil,
              encryptionKey != nil, let contents else { throw OathWalletError.locked }
        guard contents.wallets.isEmpty else { return false }
        let fingerprint = try storage.read(Self.legacyCompletionAccount).map { String(decoding: $0, as: UTF8.self) }
        resetting = true
        lock()
        do {
            _ = try await database().beginEmptyWalletReset(legacyFingerprint: fingerprint)
            return true
        } catch {
            OathDiagnostics.record(error, component: "wallet_startup", operation: "empty_wallet_reset", context: ["stage": "journal"])
            resetting = false
            throw error
        }
    }

    func hasPendingReset() async throws -> Bool {
        let db = try await database()
        return try await db.pendingWalletReset() != nil
    }

    func beginReset(authorization: UUID, now: ContinuousClock.Instant = .now) async throws {
        guard !resetting, walletMutation == nil, encryptionKey != nil, profile != nil,
              let grant = resetAuthorization, grant.id == authorization,
              now <= grant.deadline else { throw OathWalletError.locked }
        resetting = true
        lock() // Invalidate every suspended vault operation before any await.
        do {
            let db = try await database()
            _ = try await db.beginWalletReset()
        } catch { OathDiagnostics.record(error);
            resetting = false
            throw error // Nothing has been erased. The old vault remains locked.
        }
    }

    /// Called before normal startup reads and after confirmation. Every step is
    /// idempotent; failure keeps the durable journal and blocks all wallet use.
    @discardableResult
    func resumeResetIfNeeded() async throws -> Bool {
        guard !resetWorkInProgress else { throw OathWalletError.unavailable }
        resetWorkInProgress = true
        defer { resetWorkInProgress = false }
        let db = try await database()
        guard let resetID = try await db.pendingWalletReset() else { return false }
        let legacyRecovery = try await db.pendingLegacyRecoveryReset()
        let emptyWallet = try await db.pendingEmptyWalletReset()
        resetting = true
        lock()
        await resetEnvironment.suspend()
        try await biometricStore.disable()
        try storage.erase()
        try await db.eraseWalletData(resetID: resetID)
        if emptyWallet != nil {
            try await resetEnvironment.eraseEmptyWalletFiles()
        } else {
            try await resetEnvironment.eraseLocalFiles()
        }
        if legacyRecovery || emptyWallet != nil { try await resetEnvironment.eraseRecoveryPreferences() }
        if let fingerprint = emptyWallet?.legacyFingerprint {
            // Persist before clearing the reset journal. A crash between erasure
            // and these receipts resumes cleanup before looking at the old source.
            try storage.replace(Data(fingerprint.utf8), account: Self.legacyCompletionAccount)
            try storage.replace(Data(fingerprint.utf8), account: Self.emptyLegacyCompletionAccount)
        }
        // This is the final durable commit, after both keys and data are gone.
        try await db.finishWalletReset(resetID: resetID)
        await resetEnvironment.reopen()
        resetting = false
        return true
    }
}

struct OathWalletSetupStore: OathPasscodeSaving {
    let vault: OathWalletVault
    let phrase: OathValidatedMnemonic?
    var privateKey: OathImportedPrivateKey? = nil
    var multisig: BackupWallet.BitcoinMultisig? = nil
    var solanaMultisig: BackupWallet.SolanaMultisig? = nil
    var evmMultisig: BackupWallet.EVMMultisig? = nil
    var tonMultisig: BackupWallet.TonMultisig? = nil
    var thorchainMultisig: BackupWallet.ThorchainMultisig? = nil
    var nearMultisig: BackupWallet.NearMultisig? = nil
    var suiMultisig: BackupWallet.SuiMultisig? = nil
    var aptosMultisig: BackupWallet.AptosMultisig? = nil
    var stellarMultisig: BackupWallet.StellarMultisig? = nil
    var xrplMultisig: BackupWallet.XrplMultisig? = nil
    var tronMultisig: BackupWallet.TronMultisig? = nil
    func save(_ digits: [UInt8]) async throws { try await vault.create(digits: digits, importing: phrase, privateKey: privateKey, multisig: multisig, solanaMultisig: solanaMultisig, tronMultisig: tronMultisig, xrplMultisig: xrplMultisig, stellarMultisig: stellarMultisig, aptosMultisig: aptosMultisig, suiMultisig: suiMultisig, nearMultisig: nearMultisig, evmMultisig: evmMultisig, tonMultisig: tonMultisig, thorchainMultisig: thorchainMultisig) }
}
