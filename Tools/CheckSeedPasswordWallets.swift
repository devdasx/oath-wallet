import Foundation
import CryptoKit
import OathBitcoin
import OathDatabase

@main struct CheckSeedPasswordWallets {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ result: Bool, _ reason: String) { precondition(result, reason); checks += 1 }
        struct Fixture: Decodable {
            let name: String, phrase: String, password: String
            struct Address: Decodable { let address: String }
            let addresses: [Address]
        }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: URL(fileURLWithPath: ProcessInfo.processInfo.environment["OATH_ELECTRUM_FIXTURES"]!)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathSeedPassword-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory()
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        var started = false, created = 0
        for fixture in fixtures where fixture.name.hasPrefix("test_electrum_seed_") && fixture.password.isEmpty {
            let material = try ElectrumMnemonic.decode(fixture.phrase)
            let phrase = OathValidatedMnemonic(phrase: fixture.phrase, language: "electrum", electrum: material)
            let source: OathWalletProfile
            if !started { try await vault.create(digits: pin, importing: phrase); source = try await vault.unlockedProfile(); started = true }
            else { source = try await vault.addWallet(requestID: UUID(), importing: phrase) }
            let sourceID = source.id.uuidString
            guard let extended = fixtures.first(where: { $0.phrase == fixture.phrase && !$0.password.isEmpty }) else {
                check(await !vault.canAddSeedPasswordWallet(sourceID: sourceID), "Unsupported legacy format hides action")
                do { _ = try await vault.addSeedPasswordWallet(sourceID: sourceID, password: "test", requestID: UUID()); preconditionFailure("Unsupported extension accepted") }
                catch { check(true, "Legacy extension rejected at vault boundary") }
                continue
            }
            check(await vault.canAddSeedPasswordWallet(sourceID: sourceID), "Eligible original exposes action")
            for invalid in ["   ", String(repeating: "x", count: 4097)] {
                do { _ = try await vault.addSeedPasswordWallet(sourceID: sourceID, password: invalid, requestID: UUID()); preconditionFailure("Invalid password accepted") }
                catch OathWalletError.invalidPhrase { check(true, "Empty or oversized password rejected") }
            }
            let before = try await db.snapshot(walletID: sourceID, currency: "USD")
            let request = UUID()
            let child = try await vault.addSeedPasswordWallet(sourceID: sourceID, password: extended.password, requestID: request)
            created += 1
            check(child.id == request && child.addresses.count == 1 && child.addresses[0].chain == .bitcoin, "Separate Bitcoin-only wallet")
            check(child.addresses[0].address == extended.addresses[0].address && child.addresses[0].address != source.addresses[0].address, "Password wallet matches Electrum reference address")
            let snapshot = try await db.snapshot(walletID: child.id.uuidString, currency: "USD")
            check(snapshot.wallet.parentWalletID == sourceID && snapshot.wallet.nameGroup == "passphrase" && snapshot.wallet.nameIndex == created, "Child has stable sequential family metadata")
            check(snapshot.wallet.kind == (material.kind.isTwoFactor ? "electrum2fa" : "electrum"), "Family keeps Electrum derivation kind")
            check(snapshot.wallet.needsCustomization == true && !snapshot.wallet.backedUp, "New wallet enters existing customization flow")
            let after = try await db.snapshot(walletID: sourceID, currency: "USD")
            check(before.wallet == after.wallet && before.accounts == after.accounts, "Source remains unchanged")
            check(await !vault.canAddSeedPasswordWallet(sourceID: child.id.uuidString), "Extension wallet has no recursive Add Password action")
            let retry = try await vault.addSeedPasswordWallet(sourceID: sourceID, password: extended.password, requestID: request)
            check(retry.id == child.id, "Retry is idempotent")
            do { _ = try await vault.addSeedPasswordWallet(sourceID: sourceID, password: extended.password.uppercased(), requestID: UUID()); preconditionFailure("Equivalent password duplicated") }
            catch OathWalletError.duplicatePassphraseWallet(let id) { check(id == child.id, "Electrum normalization deduplicates") }
            let bytes = try storage.read("vault-v1")!
            let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: bytes)
            let contents = try envelope.openContents(using: envelope.key(for: pin))
            let stored = contents.wallets.first { $0.id == child.id }!
            check(envelope.version == 27 && stored.hasValidMaterial && stored.electrum?.passphrase == extended.password, "Authenticated format preserves extension and family")
            check(bytes.range(of: Data(extended.password.utf8)) == nil, "Password never stored in plaintext vault")
            var downgraded = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            downgraded["version"] = 26
            let old = try JSONDecoder().decode(OathVaultEnvelope.self, from: JSONSerialization.data(withJSONObject: downgraded))
            do { _ = try old.openContents(using: old.key(for: pin)); preconditionFailure("Downgrade accepted") } catch { check(true, "Older vault formats cannot misread child") }
            await vault.lock()
            let restart = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
            let reopened = try await restart.unlock(digits: pin)
            check(reopened.id == child.id && reopened.addresses == child.addresses, "Fresh instance restores exact password wallet")
            let recovery = try await restart.recoveryMaterial(walletID: child.id.uuidString, digits: pin)
            check(recovery.passphrase == extended.password, "Recovery view preserves password")
            await restart.lock()
            _ = try await vault.unlock(digits: pin)
            let tree = WalletTree([after.wallet, snapshot.wallet])
            check(tree.roots.count == 1 && tree.roots[0].children.first?.id == child.id.uuidString, "Wallet tree nests Electrum child")
            check(tree.movingRows(IndexSet(integer: 0), to: 2) == [sourceID, child.id.uuidString], "Parent reorder carries child")
        }
        check(created == 4, "All extension-capable Electrum formats covered")
        let bip39 = OathMnemonicValidator.bundled!.verifiedPhrase(String(repeating: "abandon ", count: 11) + "about")!
        let base = try await vault.addWallet(requestID: UUID(), importing: bip39)
        check(await !vault.canAddSeedPasswordWallet(sourceID: base.id.uuidString), "BIP39 never enters Electrum password flow")
        let bip39Child = try await vault.addPassphraseWallet(sourceID: base.id.uuidString, passphrase: "BIP39 test", requestID: UUID())
        check(bip39Child.addresses.count == OathImportChain.allCases.count, "Existing BIP39 passphrase wallets remain multichain")
        let row = try await db.snapshot(walletID: bip39Child.id.uuidString, currency: "USD")
        check(row.wallet.kind == "passphrase" && row.wallet.parentWalletID == base.id.uuidString, "Existing BIP39 family retained")
        let storedBeforeCancellation = try storage.read("vault-v1")!
        let cancelled = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await vault.addSeedPasswordWallet(sourceID: base.id.uuidString, password: "cancelled", requestID: UUID())
        }
        do { try await cancelled.value; preconditionFailure("Cancelled request completed") }
        catch is CancellationError { check(try storage.read("vault-v1") == storedBeforeCancellation, "Cancellation never writes recovery material") }
        let session = OathWalletSession(vault: vault)
        let model = OathPassphraseWalletModel(sourceID: base.id.uuidString, session: session, usesSeedPassword: true)
        model.passphrase = " Tést  PASSWORD "; model.confirmation = "test password"
        check(model.canSubmit && model.validationNotice == nil, "Form follows Electrum normalization")
        model.confirmation = "different"; check(!model.canSubmit, "Mismatched confirmation is blocked")
        model.cancel(); check(model.passphrase.isEmpty && model.confirmation.isEmpty, "Leaving form clears password")
        print("Passed \(checks) password-wallet host checks across \(created) Electrum formats, reference addresses, persistence, families, deduplication and BIP39 regression.")
    }
}
