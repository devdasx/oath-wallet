import Foundation
import OathCloudBackup
import OathDatabase

extension CheckMultiWallet {
    /// Actual vault encryption, backup crypto, SQL and session routing. The
    /// host harness substitutes only iOS-only WalletCore address derivation.
    @MainActor static func checkCloudRestore() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathRestore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8, 4, 1, 7, 2, 6]
        let wordsDirectory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_TEST_WORDLISTS"]!)
        let validator = try OathMnemonicValidator.load { name, ext in wordsDirectory.appendingPathComponent(name + "." + ext) }
        let words = String(repeating: "abandon ", count: 11) + "about" // Public BIP-39 vector, never real funds.
        let accounts: [BackupWallet.Account] = [
            .init(network: "ethereum", derivationPath: "m/44'/60'/0'/0/0", index: 0),
            .init(network: "ethereum", derivationPath: "m/44'/60'/3'/0/0", index: 3),
            .init(network: "bitcoin", derivationPath: "m/84'/0'/0'/0/0", index: 0)
        ]
        let originalParentID = UUID()
        let original = BackupWallet(id: UUID(), name: "Restored travel", mnemonic: words, language: "english",
            createdAt: Date(timeIntervalSince1970: 1234), accounts: accounts, colorHex: "DF438D", passphrase: " public fixture ", parentWalletID: originalParentID)
        let encrypted = try BackupDocument.seal(original, password: "fixture-backup-password")
        let prepared = try OathRestoredWallet(backup: BackupDocument.open(encrypted, password: "fixture-backup-password"), validator: validator)
        try await OathRestoredWalletSetupStore(vault: vault, restoration: prepared).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding && session.pendingCustomizationID == nil,
              "First restore must finish app-lock setup without customization")
        check(session.portfolio?.wallet.name == "" && session.portfolio?.wallet.nameGroup == "passphrase" && session.portfolio?.wallet.nameIndex == 1 && session.portfolio?.wallet.colorHex == original.colorHex,
              "A restored passphrase wallet gets its numbered default and preserves color")
        check(session.portfolio?.wallet.createdAt == 1234 && session.portfolio?.wallet.kind == "passphrase",
              "Creation date and wallet kind must be restored")
        check(session.portfolio?.wallet.parentWalletID == originalParentID.uuidString && WalletTree(session.wallets).roots.count == 1,
              "A child restores independently when its parent is absent")
        check(session.portfolio?.accounts.count == 3 && session.portfolio?.accounts.contains(where: {
            $0.networkID == "ethereum" && $0.accountIndex == 3 && $0.derivationPath == accounts[1].derivationPath
        }) == true, "Each restored account must retain its index and path")
        let credential = try await vault.biometricCredential()
        await biometrics.enroll(credential)
        let firstRows = try await db.snapshot(walletID: original.id.uuidString, currency: "USD")
        let key = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: ["ethereum", "base"])
        let second = BackupWallet(id: UUID(), name: "Key fixture", mnemonic: "", language: "", createdAt: .now,
            accounts: key.networks.map { .init(network: $0, derivationPath: "imported", index: 0) }, colorHex: "209750", privateKey: key)
        let next = try OathRestoredWallet(backup: second)
        try await session.restoreWallet(next)
        check(session.wallets.count == 2 && session.displayedProfile?.id == second.id && session.pendingCustomizationID == nil,
              "Additional restore must add and select the recovered wallet without new setup")
        let unchanged = try await db.snapshot(walletID: original.id.uuidString, currency: "USD")
        check(unchanged.wallet == firstRows.wallet && unchanged.accounts == firstRows.accounts,
              "Restoring must not change any existing wallet")
        let beforeRetry = try storage.read("vault-v1")
        try await session.restoreWallet(next)
        check(try session.wallets.count == 2 && storage.read("vault-v1") == beforeRetry,
              "Repeated restoration must not duplicate or rewrite a committed wallet")
        let duplicate = BackupWallet(id: UUID(), name: "Duplicate", mnemonic: "", language: "", createdAt: .now,
            accounts: second.accounts, privateKey: key)
        try await session.restoreWallet(OathRestoredWallet(backup: duplicate))
        check(session.wallets.count == 2 && session.displayedProfile?.id == second.id,
              "The same keys under a different backup ID must select the existing wallet")

        let collision = BackupWallet(id: original.id, name: "Collision", mnemonic: "", language: "", createdAt: .now,
            accounts: second.accounts, privateKey: key)
        do { try await session.restoreWallet(OathRestoredWallet(backup: collision)); preconditionFailure("Identity collision replaced a wallet") }
        catch { check(error as? CloudBackupError == .fileConflict, "UUID conflict must be explicit") }
        check(try storage.read("vault-v1") == beforeRetry, "Collision must not mutate encrypted storage")

        // Repair after ciphertext committed but SQL did not survive.
        try await db.deleteWalletMetadata(original.id.uuidString)
        await session.lock()
        let reopened = OathWalletSession(vault: OathWalletVault(storage: storage, biometricStore: biometrics, database: db))
        await reopened.load()
        check(reopened.isLocked, "Restored wallets must remain protected on cold launch")
        await reopened.unlock(pin)
        check(reopened.isUnlocked && reopened.wallets.count == 2, "Existing app passcode must still unlock every member")
        let repaired = try await db.snapshot(walletID: original.id.uuidString, currency: "USD")
        check(repaired.wallet.name.isEmpty && repaired.wallet.nameGroup == "passphrase" && repaired.wallet.nameIndex == 1 && repaired.wallet.colorHex == original.colorHex && !repaired.wallet.needsCustomization,
              "Interrupted metadata commit must recover the automatic restored-name category and color")
        check(repaired.accounts.map(\.derivationPath).sorted() == accounts.map(\.derivationPath).sorted(),
              "Interrupted metadata commit must recover nondefault account paths")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets.first?.passphrase == original.passphrase && contents.wallets.last?.privateKey?.bytes == key.bytes,
              "Both passphrase and imported key material must survive encrypted cold storage")
        check(!String(decoding: raw, as: UTF8.self).contains(words), "Restore must not store plaintext recovery material")
        let enabled = try await reopened.vault.securityState()
        check(enabled.passcodeEnabled && enabled.biometricsEnabled, "Restoration must preserve security enrollment")

        let thirdKey = BackupWallet.ImportedPrivateKey(bytes: Data(repeating: 9, count: 32), networks: ["ethereum"])
        let third = try OathRestoredWallet(backup: .init(id: UUID(), name: "Retry fixture", mnemonic: "", language: "", createdAt: .now,
            accounts: [.init(network: "ethereum", derivationPath: "imported", index: 0)], privateKey: thirdKey))
        storage.rejectNextUpdate()
        do { try await reopened.restoreWallet(third); preconditionFailure("Failed Keychain write was ignored") }
        catch { check(true, "Storage failure is reported") }
        check(try storage.read("vault-v1") == raw && reopened.wallets.count == 2,
              "Failed vault commit must not leave a phantom SQL wallet")
        try await reopened.restoreWallet(third)
        check(reopened.wallets.count == 3, "A failed restore must be retryable")
        let parent = BackupWallet(id: originalParentID, name: "Original", mnemonic: words, language: "english",
            createdAt: Date(timeIntervalSince1970: 1000), accounts: accounts)
        try await reopened.restoreWallet(OathRestoredWallet(backup: parent, validator: validator))
        check(WalletTree(reopened.wallets).roots.first { $0.id == originalParentID.uuidString }?.children.first?.id == original.id.uuidString,
              "Restoring the original parent reconnects its independently restored child")
        await reopened.lock()
        do { try await reopened.restoreWallet(third); preconditionFailure("Locked session restored a wallet") }
        catch { check(error as? OathWalletError == .locked, "Restore requires an unlocked existing app") }

        for badAccounts: [BackupWallet.Account] in [[],
            [.init(network: "not-supported", derivationPath: "m/44'/60'/0'/0/0", index: 0)],
            [.init(network: "ethereum", derivationPath: "m/not-a-path", index: 0)],
            [.init(network: "ethereum", derivationPath: "m/2147483648", index: 0)],
            [accounts[0], accounts[0]]] {
            let invalid = BackupWallet(id: UUID(), name: "Invalid fixture", mnemonic: words, language: "english", createdAt: .now, accounts: badAccounts)
            do { _ = try OathRestoredWallet(backup: invalid, validator: validator); preconditionFailure("Malformed account metadata restored") }
            catch { check(error as? CloudBackupError == .invalidDocument, "Malformed account descriptor must fail closed") }
        }
        print("Passed \(checks) cloud-restore integration checks (local synthetic backups; no live iCloud).")
        return checks
    }
}
