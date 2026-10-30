import Foundation
import OathAnkr
import OathCloudBackup
import OathDatabase

@main struct CheckThorchainMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Deterministic unfunded fixture keys, never used for real funds.
        let signerKeys = [Data(repeating: 22, count: 32), Data(repeating: 23, count: 32), Data(repeating: 24, count: 32)]
        let signers = try signerKeys.map { try BackupWallet.ThorchainMultisig.Signer(publicKey: ThorchainSendCrypto.publicKey(privateKey: $0), key: $0) }
        let address = try ThorchainMultisigPolicy(required: 2, publicKeys: signers.map(\.publicKey)).address(network: .mainnet)
        let material = BackupWallet.ThorchainMultisig(required: 2, address: address, signers: signers)
        try material.validateMaterial()
        check(try material.policy().required == 2, "Policy retains threshold")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathThorchainMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, thorchainMultisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "thorchainMultisig" && session.portfolio?.accounts.count == 1, "Wallet is Thorchain-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 19, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].thorchainMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: signerKeys[0]) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let account = try await db.accounts(walletID:contents.wallets[0].id.uuidString).first!
        let policy = try material.policy()
        let recipient = try ThorchainSendCrypto.address(publicKey: ThorchainSendCrypto.publicKey(privateKey: Data(repeating: 30, count: 32)), network: .mainnet)
        let plan = ThorchainSendPlan(network: .mainnet, sender: address, recipient: recipient, reference: "native", publicKey: policy.aminoPublicKey, decimals: 8, requestedAmount: "1", amount: "1", assetBalance: "1000000000", nativeBalance: "1000000000", accountNumber: 1, sequence: 2, fee: 2000000, height: 100, timeoutHeight: 130, multisig: policy)
        let quote = OathThorchainQuote(walletID:account.walletID,accountID:account.id,assetID:"thorchain:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"multisig-send",walletID:quote.walletID,accountID:account.id,networkID:"thorchain",assetID:quote.assetID,idempotencyKey:"multisig-send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueThorchainSend(sendID:"multisig-send",plan:plan)
        do { _ = try await vault.signThorchainSend(sendID:"multisig-send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN cannot authorize multisig") }
        do { _ = try await vault.signThorchainSend(sendID:"multisig-send",quote:quote,digits:nil,reason:"Test");preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics requires PIN fallback") }
        let signed = try await vault.signThorchainSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test")
        try ThorchainSendCrypto.verify(signed,plan:plan)
        check(signed.signature.count == 2 + 66 * policy.required,"Freshly authenticated vault signs with exact quorum")
        try await db.journalThorchainSignature(sendID:"multisig-send",signed:signed)
        let journal = try await db.send("multisig-send")
        check(journal?.state == "signed" && journal?.signedPayload != nil,"Exact signatures persisted before broadcast")
        check(try await db.thorchainSendPlan(sendID:"multisig-send") == plan,"Recovery preserves exact policy and intent")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let persisted = try await reopened.send("multisig-send")
        check(persisted?.signedPayload == journal?.signedPayload, "Reopening the database preserves every signed proposal and confirmation")
        let recovered = try JSONDecoder().decode(ThorchainSignedSend.self, from: persisted!.signedPayload!)
        try ThorchainSendCrypto.verify(recovered, plan: plan)
        check(recovered == signed, "Restart recovery reuses the exact signed bundle without authorizing again")
        await session.lock()
        do { _ = try await vault.signThorchainSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test");preconditionFailure("Locked signed") }
        catch { check(error as? OathWalletError == .locked,"Lock prevents stale multisig authorization") }
        await session.unlock(pin)
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.thorchainMultisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.thorchainMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let draft = OathMultisigDraft(); draft.chain = .thorchain; draft.resize(7)
        check(draft.slots.count == 7, "Thorchain allows seven signers")
        draft.resize(8); check(draft.slots.count == 7, "Thorchain rejects eight signers")
        draft.changeSource(.wif, at: 0); draft.slots[0].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 0)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[0].thorchainMaterial == signers[0] && draft.slots[0].input.isEmpty, "Thorchain raw key validates and clears input")
        draft.changeSource(.wif, at: 1); draft.slots[1].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 1)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[1].notice == .multisigDuplicateKey && draft.slots[1].thorchainMaterial == nil, "Duplicate signer rejected")
        draft.clear(); check(draft.slots.allSatisfy { $0.thorchainMaterial == nil }, "Clear drops signer material")
        draft.resize(2)
        for i in 0..<2 {
            draft.changeSource(.wif, at: i)
            draft.slots[i].input = "0x" + String(repeating: i == 0 ? "16" : "17", count: 32)
            draft.prepareKey(at: i)
            for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        check(draft.ready, "Raw hex signer inputs prepare the threshold wallet")
        var finished: BackupWallet.ThorchainMultisig?
        draft.finishThorchain { finished = $0 }
        for _ in 0..<1000 where draft.preparing { try await Task.sleep(for: .milliseconds(10)) }
        check(finished?.required == 2 && finished?.signers.count == 2, "Creation returns the complete threshold bundle")
        check(try finished?.policy().address(network: .mainnet) == finished?.address, "Creation address is bound to canonical signer policy")
        draft.clear()
        print("Passed \(checks) Thorchain raw-key host integration checks: draft, limits, passcode, encrypted vault, lock/unlock and encrypted backup restore. WalletCore HD derivation and live network transfers are separate checks.")
    }
}
