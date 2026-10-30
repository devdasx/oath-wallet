import Foundation
import OathAnkr
import OathCloudBackup
import OathDatabase

@main struct CheckSuiMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Deterministic unfunded fixture keys, never used for real funds.
        let signerKeys = [Data(repeating: 22, count: 32), Data(repeating: 23, count: 32), Data(repeating: 24, count: 32)]
        let signers = try signerKeys.map { try BackupWallet.SuiMultisig.Signer(publicKey: SuiSendCrypto.publicKey(privateKey: $0), key: $0) }
        let address = try SuiMultisigPolicy(required: 2, publicKeys: signers.map(\.publicKey)).address
        let material = BackupWallet.SuiMultisig(required: 2, address: address, signers: signers)
        try material.validateMaterial()
        check(try material.policy().required == 2, "Policy retains threshold")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathSuiMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, suiMultisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "suiMultisig" && session.portfolio?.accounts.count == 1, "Wallet is Sui-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 17, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].suiMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: signerKeys[0]) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let account = try await db.accounts(walletID:contents.wallets[0].id.uuidString).first!
        let policy = try material.policy()
        let funds = SuiSendFunds(coins: [], addressBalance: 1_000_000_000)
        let plan = try SuiSendPlan.make(network: .mainnet, sender: address, recipient: "0xabc", reference: "native", amount: 1_000_000, native: funds, asset: funds, gasPrice: 1000, gasBudget: 5_000_000, epoch: 1252, multisig: policy)
        let quote = OathSuiQuote(walletID:account.walletID,accountID:account.id,assetID:"sui:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"multisig-send",walletID:quote.walletID,accountID:account.id,networkID:"sui",assetID:quote.assetID,idempotencyKey:"multisig-send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueSuiSend(sendID:"multisig-send",plan:plan)
        do { _ = try await vault.signSuiSend(sendID:"multisig-send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN cannot authorize multisig") }
        do { _ = try await vault.signSuiSend(sendID:"multisig-send",quote:quote,digits:nil,reason:"Test");preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics requires PIN fallback") }
        let signed = try await vault.signSuiSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test")
        try SuiSendCrypto.verify(signed,sender:plan.sender)
        check(signed.signature.first == 3,"Freshly authenticated vault signs with exact quorum")
        try await db.journalSuiSignature(sendID:"multisig-send",signed:signed)
        let journal = try await db.send("multisig-send")
        check(journal?.state == "signed" && journal?.signedPayload != nil,"Exact signatures persisted before broadcast")
        check(try await db.suiSendPlan(sendID:"multisig-send") == plan,"Recovery preserves exact policy and intent")
        await session.lock()
        do { _ = try await vault.signSuiSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test");preconditionFailure("Locked signed") }
        catch { check(error as? OathWalletError == .locked,"Lock prevents stale multisig authorization") }
        await session.unlock(pin)
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.suiMultisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.suiMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let draft = OathMultisigDraft(); draft.chain = .sui; draft.resize(10)
        check(draft.slots.count == 10, "Sui allows ten signers")
        draft.resize(11); check(draft.slots.count == 10, "Sui rejects eleven signers")
        draft.changeSource(.wif, at: 0); draft.slots[0].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 0)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[0].suiMaterial == signers[0] && draft.slots[0].input.isEmpty, "Sui raw key validates and clears input")
        draft.changeSource(.wif, at: 1); draft.slots[1].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 1)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[1].notice == .multisigDuplicateKey && draft.slots[1].suiMaterial == nil, "Duplicate signer rejected")
        draft.clear(); check(draft.slots.allSatisfy { $0.suiMaterial == nil }, "Clear drops signer material")
        draft.resize(2)
        for i in 0..<2 {
            draft.changeSource(.wif, at: i)
            draft.slots[i].input = "0x" + String(repeating: i == 0 ? "16" : "17", count: 32)
            draft.prepareKey(at: i)
            for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        check(draft.ready, "Raw hex signer inputs prepare the threshold wallet")
        var finished: BackupWallet.SuiMultisig?
        draft.finishSui { finished = $0 }
        for _ in 0..<1000 where draft.preparing { try await Task.sleep(for: .milliseconds(10)) }
        check(finished?.required == 2 && finished?.signers.count == 2, "Creation returns the complete threshold bundle")
        check(try finished?.policy().address == finished?.address, "Creation address is bound to canonical signer policy")
        draft.clear()
        print("Passed \(checks) Sui raw-key host integration checks: draft, limits, passcode, encrypted vault, lock/unlock and encrypted backup restore. WalletCore HD derivation and live network transfers are separate checks.")
    }
}
