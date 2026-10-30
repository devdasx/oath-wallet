import Foundation
import OathAnkr
import OathCloudBackup
import OathDatabase

@main struct CheckNearMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Deterministic unfunded fixture keys, never used for real funds.
        let signerKeys = [Data(repeating: 22, count: 32), Data(repeating: 23, count: 32), Data(repeating: 24, count: 32)]
        let signers = try signerKeys.map { try BackupWallet.NearMultisig.Signer(publicKey: NearSendCrypto.publicKey(privateKey: $0), key: $0) }
        let bootstrap = Data(repeating: 25, count: 32)
        let address = try NearMultisigPolicy(bootstrap: NearSendCrypto.publicKey(privateKey: bootstrap), required: 2, publicKeys: signers.map(\.publicKey)).address
        let material = BackupWallet.NearMultisig(bootstrapSeed: bootstrap, required: 2, address: address, signers: signers)
        try material.validateMaterial()
        check(try material.policy().required == 2, "Policy retains threshold")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathNearMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, nearMultisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "nearMultisig" && session.portfolio?.accounts.count == 1, "Wallet is Near-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 18, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].nearMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: signerKeys[0]) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let account = try await db.accounts(walletID:contents.wallets[0].id.uuidString).first!
        let policy = try material.policy()
        let plan = NearSendPlan(network: .mainnet, sender: address, recipient: "recipient.near", reference: "native", publicKey: policy.publicKeys[0], decimals: 24, requestedAmount: "1", amount: "1", assetBalance: "10000000000000000000000000", nativeBalance: "10000000000000000000000000", reserve: "4000000000000000000000000", storageDeposit: "0", fee: "100000000000000000000000", gasPriceCeiling: "200000000", gas: 0, storageGas: 0, nonce: 10, blockHash: "11111111111111111111111111111111", blockHeight: 100, validityPeriod: 86400, multisig: .init(policy: policy, stage: .transfer, requestID: 0, nonces: [10,10]))
        let quote = OathNearQuote(walletID:account.walletID,accountID:account.id,assetID:"near:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"multisig-send",walletID:quote.walletID,accountID:account.id,networkID:"near",assetID:quote.assetID,idempotencyKey:"multisig-send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueNearSend(sendID:"multisig-send",plan:plan)
        do { _ = try await vault.signNearSend(sendID:"multisig-send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN cannot authorize multisig") }
        do { _ = try await vault.signNearSend(sendID:"multisig-send",quote:quote,digits:nil,reason:"Test");preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics requires PIN fallback") }
        let signed = try await vault.signNearSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test")
        try NearSendCrypto.verify(signed,plan:plan)
        check(signed.multisigParts?.count == 3,"Freshly authenticated vault signs with exact quorum")
        try await db.journalNearSignature(sendID:"multisig-send",signed:signed)
        let journal = try await db.send("multisig-send")
        check(journal?.state == "signed" && journal?.signedPayload != nil,"Exact signatures persisted before broadcast")
        check(try await db.nearSendPlan(sendID:"multisig-send") == plan,"Recovery preserves exact policy and intent")
        let reopened = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        let persisted = try await reopened.send("multisig-send")
        check(persisted?.signedPayload == journal?.signedPayload, "Reopening the database preserves every signed proposal and confirmation")
        let recovered = try JSONDecoder().decode(NearSignedSend.self, from: persisted!.signedPayload!)
        try NearSendCrypto.verify(recovered, plan: plan)
        check(recovered == signed, "Restart recovery reuses the exact signed bundle without authorizing again")
        await session.lock()
        do { _ = try await vault.signNearSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test");preconditionFailure("Locked signed") }
        catch { check(error as? OathWalletError == .locked,"Lock prevents stale multisig authorization") }
        await session.unlock(pin)
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.nearMultisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.nearMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let draft = OathMultisigDraft(); draft.chain = .near; draft.resize(10)
        check(draft.slots.count == 10, "Near allows ten signers")
        draft.resize(11); check(draft.slots.count == 10, "Near rejects eleven signers")
        draft.changeSource(.wif, at: 0); draft.slots[0].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 0)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[0].nearMaterial == signers[0] && draft.slots[0].input.isEmpty, "Near raw key validates and clears input")
        draft.changeSource(.wif, at: 1); draft.slots[1].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 1)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[1].notice == .multisigDuplicateKey && draft.slots[1].nearMaterial == nil, "Duplicate signer rejected")
        draft.clear(); check(draft.slots.allSatisfy { $0.nearMaterial == nil }, "Clear drops signer material")
        draft.resize(2)
        for i in 0..<2 {
            draft.changeSource(.wif, at: i)
            draft.slots[i].input = "0x" + String(repeating: i == 0 ? "16" : "17", count: 32)
            draft.prepareKey(at: i)
            for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        check(draft.ready, "Raw hex signer inputs prepare the threshold wallet")
        var finished: BackupWallet.NearMultisig?
        draft.finishNear { finished = $0 }
        for _ in 0..<1000 where draft.preparing { try await Task.sleep(for: .milliseconds(10)) }
        check(finished?.required == 2 && finished?.signers.count == 2, "Creation returns the complete threshold bundle")
        check(try finished?.policy().address == finished?.address, "Creation address is bound to canonical signer policy")
        draft.clear()
        print("Passed \(checks) Near raw-key host integration checks: draft, limits, passcode, encrypted vault, lock/unlock and encrypted backup restore. WalletCore HD derivation and live network transfers are separate checks.")
    }
}
