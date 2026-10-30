import Foundation
import OathBitcoin
import OathCloudBackup
import OathDatabase

@main struct CheckBitcoinMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func settle(_ draft: OathMultisigDraft) async throws {
            for _ in 0..<1000 {
                if draft.working == nil && !draft.preparing { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("Fixture operation timed out")
        }
        // Published BIP39 vector and deterministic scalar; no real wallet data.
        let words = String(repeating: "abandon ", count: 11) + "about"
        let wif = try BitcoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: true)
        let draft = OathMultisigDraft()
        draft.resize(2)
        draft.changeSource(.wif, at: 0); draft.slots[0].input = "invalid"
        draft.prepareKey(at: 0); try await settle(draft)
        check(!draft.ready && draft.slots[0].notice == .privateKeyInvalid, "Invalid WIF cannot advance")
        draft.slots[0].input = wif; draft.prepareKey(at: 0); try await settle(draft)
        draft.changeSource(.phrase, at: 1); draft.slots[1].input = words; draft.slots[1].passphrase = "TREZOR"
        draft.prepareKey(at: 1); try await settle(draft)
        check(draft.ready && draft.slots.allSatisfy { $0.input.isEmpty && $0.passphrase.isEmpty }, "Validated entries move out of editable fields")
        var prepared: BackupWallet.BitcoinMultisig?
        draft.finish { prepared = $0 }; try await settle(draft)
        let material = prepared!
        check(material.required == 2 && material.signers.count == 2, "Threshold and all keys reach passcode setup")
        let descriptor = try material.descriptor()
        let address = try BitcoinKeys.addresses(branch: descriptor.branches[0], range: 0..<1)[0].address
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, multisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "bitcoinMultisig" && session.portfolio?.accounts.count == 1, "Wallet is Bitcoin-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let accountID = session.portfolio!.accounts[0].id
        let receive = try await db.bitcoinReceiveAddress(accountID: accountID)
        let change = try await db.bitcoinChangeAddress(accountID: accountID)
        check(receive.multisigInputWeight != nil && change.multisigInputWeight != nil,
            "SQL receive and change metadata retain multisig fee weights")
        check(receive.address == address && change.address != address, "HD multisig change is distinct")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 11, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].bitcoinMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: Data(words.utf8)) == nil && raw.range(of: Data(wif.utf8)) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.multisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.bitcoinMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let alternate = OathMultisigDraft(); alternate.resize(2)
        for i in 0..<2 { alternate.changeSource(.wif, at: i); alternate.slots[i].input = wif; alternate.prepareKey(at: i); try await settle(alternate) }
        alternate.finish { _ in preconditionFailure("Duplicate signer accepted") }; try await settle(alternate)
        check(alternate.notice == .multisigDuplicateKey, "Duplicate signer cannot bypass policy validation")
        alternate.clear(); draft.clear()
        check(!draft.ready && draft.slots.allSatisfy { $0.material == nil }, "Leaving setup clears pending key material")
        print("Passed \(checks) multisig host integration checks: setup, validation, passcode, vault, public metadata, lock/unlock and encrypted restore. No device or live funds used.")
    }
}
