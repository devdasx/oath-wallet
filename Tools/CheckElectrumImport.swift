import Foundation
import CryptoKit
import OathBitcoin
import OathDatabase

@main struct CheckElectrumImport {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        struct Fixture: Decodable { let name: String; let phrase: String; let password: String; let kind: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_ELECTRUM_FIXTURES"]!)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathElectrumImport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory()
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        var created = false
        var kinds = Set<String>()
        for fixture in fixtures where fixture.name.hasPrefix("test_electrum_seed_") {
            kinds.insert(fixture.kind)
            let material = try ElectrumMnemonic.decode(fixture.phrase, passphrase: fixture.password)
            let phrase = OathValidatedMnemonic(phrase: fixture.phrase, language: "electrum", electrum: material)
            let secret = try OathWalletEngine.imported(phrase)
            check(secret.hasValidMaterial && secret.electrum == material, "Production import retains Electrum material")
            do { _ = try secret.bip39Passphrase; preconditionFailure("Electrum treated as BIP39") } catch { check(true, "BIP39 derivation refuses Electrum") }
            let draft = OathRecoveryPhraseDraft()
            check(draft.receiveScan(fixture.phrase), "QR accepts Electrum")
            draft.selectFormat(.electrum)
            check(draft.isElectrum && draft.submit() == nil, "Electrum cannot silently use BIP39")
            draft.clear()
            check(draft.text.isEmpty && draft.preferredFormat == nil, "Leaving import clears phrase and format choice")
            let profile: OathWalletProfile
            if !created { try await vault.create(digits: pin, importing: phrase); profile = try await vault.unlockedProfile(); created = true }
            else { profile = try await vault.addWallet(requestID: UUID(), importing: phrase) }
            check(profile.addresses.count == 1 && profile.addresses[0].chain == .bitcoin, "Bitcoin-only profile")
            let snapshot = try await db.snapshot(walletID: profile.id.uuidString, currency: "USD")
            check(snapshot.wallet.kind == (material.kind.isTwoFactor ? "electrum2fa" : "electrum") && snapshot.accounts.count == 1, "Bitcoin-only database identity")
            let receive = try await db.bitcoinReceiveAddress(accountID: snapshot.accounts[0].id)
            check(receive.address == profile.addresses[0].address, "Ready receive address matches derivation")
            let state = try await db.bitcoinState(accountID: snapshot.accounts[0].id)
            check(state?.descriptor == (try ElectrumBitcoin.wallet(material)), "Exact public policy survives persistence")
            let raw = try storage.read("vault-v1")!
            let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
            check(envelope.version == 26, "Older apps cannot misinterpret Electrum vaults")
            let opened = try envelope.openContents(using: envelope.key(for: pin))
            check(opened.wallets.contains { $0.id == profile.id && $0.electrum == material }, "Vault encryption round trip")
            check(raw.range(of: Data(fixture.phrase.utf8)) == nil, "No plaintext recovery in persisted vault")
            await vault.lock()
            _ = try await vault.unlock(digits: pin)
            let recovered = try await vault.recoveryMaterial(walletID: profile.id.uuidString, digits: pin)
            check((recovered.passphrase ?? "") == fixture.password, "Seed extension survives encrypted persistence")
            check(recovered.words.joined(separator: " ") == ElectrumMnemonic.normalize(fixture.phrase), "Recovery display preserves phrase")
            let restarted = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
            let reopened = try await restarted.unlock(digits: pin)
            check(reopened.id == profile.id && reopened.addresses == profile.addresses, "Fresh vault instance preserves Bitcoin account")
            await restarted.lock()
            var downgraded = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
            downgraded["version"] = 25
            let oldFormat = try JSONDecoder().decode(OathVaultEnvelope.self, from: JSONSerialization.data(withJSONObject: downgraded))
            do { _ = try oldFormat.openContents(using: oldFormat.key(for: pin)); preconditionFailure("Vault downgrade accepted") }
            catch { check(true, "Authenticated version rejects downgrade") }
            let duplicate = try await vault.addWallet(requestID: UUID(), importing: phrase)
            check(duplicate.id == profile.id, "Reimport is idempotent")
            do { _ = try await vault.encryptedCloudBackup(walletID: profile.id.uuidString, password: "fixture-password"); preconditionFailure("Local-only seed entered cloud") } catch { check(true, "Cloud export cannot misencode Electrum as BIP39") }
        }
        for (count, iteration, address) in [(12, 1581, "36CeNMCF7nqw7C18JZrGqukjymxwFaWGvU"), (24, 2725, "3E5Y9TWVVgtYeBj19DE9SdJcdoXdoQDw7h")] {
            let last = String(UnicodeScalar(0x4e00 + iteration % 512)!) + String(UnicodeScalar(0x5000 + iteration / 512)!)
            let words = (0..<(count - 1)).map { String(UnicodeScalar(0x4e00 + $0)!) } + [last]
            let input = words.joined(separator: " ")
            let material = try ElectrumMnemonic.decode(input)
            let profile = try await vault.addWallet(requestID: UUID(), importing: .init(phrase: input, language: "electrum", electrum: material))
            check(profile.addresses.count == 1 && profile.addresses[0].address == address,
                  "CJK two-factor wallet matches an independently derived sorted multisignature address")
            let reopened = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
            _ = try await reopened.unlock(digits: pin)
            let recovered = try await reopened.recoveryMaterial(walletID: profile.id.uuidString, digits: pin)
            let decoded = try ElectrumMnemonic.decode(recovered.words.joined(separator: " "))
            check(decoded == material, "Recovered CJK two-factor words reproduce the saved cosigners")
        }
        let overlap = fixtures.first { $0.name == "bip39_electrum_overlap" }!
        let overlapDraft = OathRecoveryPhraseDraft()
        overlapDraft.replace(with: overlap.phrase)
        check(overlapDraft.hasAmbiguousFormat && !overlapDraft.isElectrum && overlapDraft.submit() != nil, "BIP39 overlap keeps default import")
        overlapDraft.selectFormat(.electrum)
        check(overlapDraft.isElectrum && overlapDraft.submit() == nil, "Electrum overlap requires explicit separate decoder")
        let bip39 = OathMnemonicValidator.bundled!.verifiedPhrase(String(repeating: "abandon ", count: 11) + "about")!
        let other = try await vault.addWallet(requestID: UUID(), importing: bip39)
        check(other.addresses.count == OathImportChain.allCases.count, "BIP39 retains multi-chain scope")
        print("Passed \(checks) Electrum host integration checks across \(kinds.count) formats: import, encrypted vault, lock/unlock, SQL, receive, recovery, deduplication and BIP39 separation.")
    }
}
