import Foundation
import OathWalletHandoff
import OathDatabase
import OathCloudBackup

/// Production import preparation, local commit and customization routing state.
/// Address derivation uses the host harness's explicit synthetic adapter.
@main struct CheckVaultHandoff {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ ok: Bool, _ message: String) { precondition(ok, message); checks += 1 }
        let inbox = OathVaultImportInbox()
        let firstReference = HandoffReference(), latestReference = HandoffReference(), queuedReference = HandoffReference()
        check(inbox.receive(firstReference.url), "Valid link is accepted while locked")
        check(inbox.receive(latestReference.url) && inbox.pending == latestReference, "New explicit tap replaces an older unconsumed link")
        check(inbox.take() == latestReference && inbox.pending == nil, "Only latest link becomes active")
        check(inbox.receive(latestReference.url) && inbox.pending == nil, "Duplicate active link is ignored")
        check(inbox.receive(queuedReference.url) && inbox.take() == nil, "Second import waits for current customization")
        inbox.finish(latestReference)
        check(inbox.take() == queuedReference, "Queued handoff becomes available after dismissal")
        inbox.finish(latestReference)
        check(inbox.active == queuedReference, "Late dismissal cannot clear a newer active import")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HandoffChecks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let vault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [4,1,7,9,2,6]
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault); await session.finishedSetup()
        // Solana's host fixture has a distinct derivation adapter and is covered
        // by the shared transport test; every other chain uses this fixture.
        for chain in OathImportChain.allCases where chain != .solana {
            let id = UUID()
            let handoff = WalletHandoff(kind: .privateKey, value: "", rawKey: Data(repeating: 1, count: 32),
                importNetworkID: chain.handoffNetworkID,
                accounts: [.init(networkID: chain.handoffNetworkID, address: "synthetic-address-" + id.uuidString + chain.id,
                                 derivationPath: "private-key:rawSecp256k1")])
            let prepared = try OathRestoredWallet(handoff: handoff, requestID: id)
            check(prepared.secret.privateKey?.networks == [chain], "Single-chain scope must remain exact")
            try await session.restoreWallet(prepared)
            check(session.displayedProfile?.id == id, "Imported wallet becomes selected")
            check(session.pendingCustomizationID == id.uuidString, "Import stops at name/color customization")
            let before = session.wallets.count
            try await session.restoreWallet(prepared)
            check(session.wallets.count == before, "Replay cannot duplicate the committed wallet")
            try await session.customizeWallet(id.uuidString, name: "Public fixture", colorHex: "288CBC")
            check(session.pendingCustomizationID == nil, "Customization completes only after local metadata save")
        }
        let id = UUID()
        let invalid = WalletHandoff(kind: .privateKey, value: "", rawKey: Data(repeating: 2, count: 32),
            importNetworkID: "tron", accounts: [.init(networkID: "eth", address: "synthetic-address-" + id.uuidString + "ethereum", derivationPath: "imported")])
        do { _ = try OathRestoredWallet(handoff: invalid, requestID: id); preconditionFailure("Mismatched chain accepted") }
        catch { check(true, "Mismatched chain rejected before commit") }
        let wrongAddress = WalletHandoff(kind: .privateKey, value: "", rawKey: Data(repeating: 2, count: 32),
            accounts: [.init(networkID: "eth", address: "different-owner", derivationPath: "imported")])
        do { _ = try OathRestoredWallet(handoff: wrongAddress, requestID: id); preconditionFailure("Wrong address accepted") }
        catch { check(true, "Address mismatch rejected before commit") }
        let incomplete = WalletHandoff(kind: .privateKey, value: "", rawKey: Data(repeating: 2, count: 32),
            accounts: [.init(networkID: "bitcoin", address: "public", derivationPath: "private-key:extendedLegacy")])
        do { _ = try OathRestoredWallet(handoff: incomplete, requestID: id); preconditionFailure("Lost chain code accepted") }
        catch { check(true, "Missing BIP32 chain code rejected") }
        let phraseID = UUID()
        let phrase = String(repeating: "abandon ", count: 11) + "about" // Public BIP39 vector.
        let recovery = WalletHandoff(kind: .recoveryPhrase, value: phrase, passphrase: " public CASE ", accounts: [
            .init(networkID: "eth", address: "synthetic-address-" + phraseID.uuidString + "ethereum", derivationPath: "m/44'/60'/0'/0/0"),
            .init(networkID: "eth", address: "synthetic-address-" + phraseID.uuidString + "ethereum:3", derivationPath: "m/44'/60'/3'/0/0", accountIndex: 3)])
        let preparedRecovery = try OathRestoredWallet(handoff: recovery, requestID: phraseID)
        check(try preparedRecovery.secret.bip39Passphrase == " public CASE ", "Recovery passphrase must retain case and spaces")
        check(preparedRecovery.profile.addresses.count == 2, "HD account paths and indexes are preserved")
        try await session.restoreWallet(preparedRecovery)
        check(session.pendingCustomizationID == phraseID.uuidString, "Passphrase wallet reaches customization")
        await vault.lock()
        do { _ = try await vault.restoreWallet(preparedRecovery); preconditionFailure("Locked import accepted") }
        catch OathWalletError.locked { check(true, "Valid material cannot bypass app unlock") }
        let firstDB = try await OathDatabase.open(at: folder.appendingPathComponent("first.sqlite"))
        try await OathDataEnvironment.seed(firstDB)
        let firstVault = OathWalletVault(storage: WalletMemory(), biometricStore: MemoryBiometrics(), database: firstDB)
        try await OathRestoredWalletSetupStore(vault: firstVault, restoration: preparedRecovery).save(pin)
        let first = OathWalletSession(vault: firstVault)
        await first.finishedSetup()
        check(first.pendingCustomizationID == phraseID.uuidString && first.presentsOnboarding, "First import retains setup host through name/color step")
        try await first.customizeWallet(phraseID.uuidString, name: "First fixture", colorHex: "288CBC")
        first.finishInitialCustomization()
        check(!first.presentsOnboarding && first.isUnlocked, "Finishing first customization opens the wallet")
        print("Vault handoff: \(checks) host checks passed; synthetic address adapter, no network or device.")
    }
}
