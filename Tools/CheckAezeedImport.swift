import Foundation
import CryptoKit
import OathAezeed
import OathBitcoin
import OathDatabase

@main struct CheckAezeedImport {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        struct Fixture: Decodable { let phrase: String; let password: String }
        let path = ProcessInfo.processInfo.environment["OATH_AEZEED_FIXTURES"]!
        let fixture = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: path)))[1]
        let material = try Aezeed.decode(fixture.phrase, passphrase: fixture.password)
        let phrase = OathValidatedMnemonic(phrase: fixture.phrase, language: "english", aezeed: material)
        let secret = try OathWalletEngine.imported(phrase)
        check(secret.hasValidMaterial && secret.aezeed == material, "Production import preserves decoded seed and exact password")
        do { _ = try secret.bip39Passphrase; preconditionFailure("aezeed treated as BIP39") }
        catch { check(true, "BIP39 derivation rejects aezeed") }
        let draft = OathRecoveryPhraseDraft()
        check(draft.receiveScan(fixture.phrase) && draft.isAezeed, "QR recovery recognizes encrypted aezeed")
        check(draft.submit() == nil, "BIP39 submit cannot accidentally bypass aezeed authentication")
        draft.clear()
        check(draft.text.isEmpty, "Leaving import clears the phrase")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathAezeedImport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory()
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await vault.create(digits: pin, importing: phrase)
        let profile = try await vault.unlockedProfile()
        check(profile.addresses.count == 1 && profile.addresses[0].chain == .bitcoin, "Only Bitcoin is exposed")
        let snapshot = try await db.snapshot(walletID: profile.id.uuidString, currency: "USD")
        check(snapshot.wallet.kind == "aezeed" && snapshot.accounts.count == 1, "Persistent kind and account scope survive import")
        check(snapshot.accounts[0].address == profile.addresses[0].address, "Persistent address matches production derivation")
        let receive = try await db.bitcoinReceiveAddress(accountID: snapshot.accounts[0].id)
        check(receive.address == profile.addresses[0].address, "Receive QR is prepared before wallet opens")
        let state = try await db.bitcoinState(accountID: snapshot.accounts[0].id)
        check(state?.descriptor.branches.first { $0.id == "49:1" }?.type == .nativeSegwit, "LND change policy is persisted")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 25, "Old apps must reject the new recovery format")
        let opened = try envelope.openContents(using: envelope.key(for: pin))
        check(opened.wallets[0].aezeed == material, "Encrypted vault round trip preserves seed and password")
        check(raw.range(of: Data(fixture.phrase.utf8)) == nil && raw.range(of: Data(fixture.password.utf8)) == nil,
              "Vault storage contains no plaintext recovery material")
        await vault.lock()
        let restored = try await vault.unlock(digits: pin)
        check(restored == profile, "Unlock restores the same Bitcoin-only profile")
        let recovery = try await vault.recoveryMaterial(walletID: profile.id.uuidString, digits: pin)
        check(recovery.words.joined(separator: " ") == fixture.phrase && recovery.passphrase == fixture.password,
              "Authenticated recovery export retains aezeed password")
        do { _ = try await vault.encryptedCloudBackup(walletID: profile.id.uuidString, password: "local-fixture"); preconditionFailure("Local-only recovery entered cloud backup") }
        catch { check(true, "Cloud export rejects local-only aezeed") }
        let restarted = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let reopened = try await restarted.unlock(digits: pin)
        check(reopened == profile, "Fresh vault instance restores the same persisted Bitcoin account")
        await restarted.lock()
        var downgraded = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        downgraded["version"] = 24
        let oldFormat = try JSONDecoder().decode(OathVaultEnvelope.self, from: JSONSerialization.data(withJSONObject: downgraded))
        do { _ = try oldFormat.openContents(using: oldFormat.key(for: pin)); preconditionFailure("Vault downgrade accepted") }
        catch { check(true, "Authenticated vault version rejects downgrade") }
        let duplicate = try await vault.addWallet(requestID: UUID(), importing: phrase)
        check(duplicate.id == profile.id, "Reimport is idempotent")
        let bip39 = OathMnemonicValidator.bundled!.verifiedPhrase(String(repeating: "abandon ", count: 11) + "about")!
        let bip39Secret = try OathWalletEngine.imported(bip39)
        check(bip39Secret.aezeed == nil && bip39Secret.hasValidMaterial, "BIP39 remains a separate valid format")
        let other = try await vault.addWallet(requestID: UUID(), importing: bip39)
        check(other.id != profile.id && other.addresses.count == OathImportChain.allCases.count, "BIP39 retains multi-chain scope")
        let repeatAezeed = try await vault.addWallet(requestID: UUID(), importing: phrase)
        check(repeatAezeed.id == profile.id && repeatAezeed.addresses.count == 1, "Mixed wallet vault retains aezeed identity")
        // One public LND fixture is also a genuine checksum-valid BIP39 phrase.
        // Independent expected receive addresses come from btcsuite, using the two distinct seeds.
        struct Overlap: Decodable { let wordIndices: [Int]; let bitcoinBIP39, bitcoinAezeed: String }
        let sample = try JSONDecoder().decode(Overlap.self, from: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_OVERLAP_FIXTURE"]!)))
        let dictionary = try String(contentsOfFile: ProcessInfo.processInfo.environment["OATH_TEST_WORDLISTS"]! + "/bip39_english.txt", encoding: .utf8).split(whereSeparator: \.isNewline)
        let words = sample.wordIndices.map { String(dictionary[$0]) }.joined(separator: " ")
        let dual = OathRecoveryPhraseDraft()
        dual.replace(with: words)
        check(dual.hasAmbiguousFormat && dual.isAezeed && dual.submit() == nil, "A recognized aezeed keeps its default without silently using BIP39")
        let decoded = try Aezeed.decode(words)
        let lndPhrase = OathValidatedMnemonic(phrase: words, language: "english", aezeed: decoded)
        let lndWallet = try await vault.addWallet(requestID: UUID(), importing: lndPhrase)
        check(lndWallet.addresses.count == 1 && lndWallet.addresses[0].address == sample.bitcoinAezeed, "LND overlap derives its independent address")
        guard let unselected = OathMnemonicValidator.bundled?.verifiedPhrase(words) else { preconditionFailure("Bad synthetic overlap") }
        do {
            _ = try OathWalletEngine.imported(unselected)
            preconditionFailure("An untyped overlap silently imported as BIP39")
        } catch OathWalletError.invalidPhrase { check(true, "Automatic aezeed-to-BIP39 downgrade stays rejected") }
        dual.selectFormat(.bip39)
        guard let chosen = dual.submit() else { preconditionFailure("Selected BIP39 overlap is unavailable") }
        let hdWallet = try await vault.addWallet(requestID: UUID(), importing: chosen)
        check(hdWallet.id != lndWallet.id && hdWallet.addresses.count == OathImportChain.allCases.count &&
              hdWallet.addresses.first(where: { $0.chain == .bitcoin })?.address == sample.bitcoinBIP39, "BIP39 overlap creates a distinct wallet with the independent Bitcoin address")
        let data = try storage.read("vault-v1")!
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: data)
        let durable = try sealed.openContents(using: sealed.key(for: pin))
        check(durable.wallets.first(where: { $0.id == lndWallet.id })?.aezeed == decoded &&
              durable.wallets.contains(where: { $0.id == hdWallet.id && $0.mnemonic == words && $0.aezeed == nil && $0.electrum == nil }), "The encrypted vault retains both format identities")
        dual.selectFormat(.aezeed)
        check(dual.isAezeed && dual.submit() == nil, "Reselecting aezeed restores its decoder")
        dual.selectFormat(.bip39)
        dual.replace(with: fixture.phrase)
        dual.replace(with: words)
        check(dual.preferredFormat == nil && dual.isAezeed, "A format selection cannot carry over to another phrase")
        print("Passed \(checks) aezeed host integration checks: actual import, local vault, Bitcoin-only SQL/receive, lock/unlock, recovery display, BIP39 separation and cloud exclusion.")
    }
}
