import Foundation
import OathAnkr
import OathCloudBackup
import OathDatabase

@main struct CheckAptosMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Deterministic unfunded fixture keys, never used for real funds.
        let signerKeys = [Data(repeating: 22, count: 32), Data(repeating: 23, count: 32), Data(repeating: 24, count: 32)]
        let signers = try signerKeys.map { try BackupWallet.AptosMultisig.Signer(publicKey: AptosSendCrypto.publicKey(privateKey: $0), key: $0) }
        let address = try AptosMultisigPolicy(required: 2, publicKeys: signers.map(\.publicKey)).address
        let material = BackupWallet.AptosMultisig(required: 2, address: address, signers: signers)
        try material.validateMaterial()
        check(try material.policy().required == 2, "Policy retains threshold")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathAptosMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, aptosMultisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "aptosMultisig" && session.portfolio?.accounts.count == 1, "Wallet is Aptos-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 16, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].aptosMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: signerKeys[0]) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let account = try await db.accounts(walletID:contents.wallets[0].id.uuidString).first!
        let policy = try material.policy()
        let plan = AptosSendPlan(network:.mainnet,sender:address,recipient:try AptosSendCrypto.address(privateKey:Data(repeating:40,count:32)),reference:"native", publicKey:policy.bytes, decimals:8,
            requestedAmount:1000000,amount:1000000,assetBalance:1000000000,nativeBalance:1000000000,
            sequence:42,gasUnitPrice:100,maxGasAmount:2000,expiration:UInt64(Date.now.timeIntervalSince1970)+300,multisig:policy)
        let quote = OathAptosQuote(walletID:account.walletID,accountID:account.id,assetID:"aptos:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"multisig-send",walletID:quote.walletID,accountID:account.id,networkID:"aptos",assetID:quote.assetID,idempotencyKey:"multisig-send",recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueAptosSend(sendID:"multisig-send",plan:plan)
        do { _ = try await vault.signAptosSend(sendID:"multisig-send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN cannot authorize multisig") }
        do { _ = try await vault.signAptosSend(sendID:"multisig-send",quote:quote,digits:nil,reason:"Test");preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics requires PIN fallback") }
        let signed = try await vault.signAptosSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test")
        try AptosSendCrypto.verify(signed,plan:plan)
        check(signed.signatures?.count == 2,"Freshly authenticated vault signs with exact quorum")
        try await db.journalAptosSignature(sendID:"multisig-send",signed:signed)
        let journal = try await db.send("multisig-send")
        check(journal?.state == "signed" && journal?.signedPayload != nil,"Exact signatures persisted before broadcast")
        check(try await db.aptosSendPlan(sendID:"multisig-send") == plan,"Recovery preserves exact policy and intent")
        await session.lock()
        do { _ = try await vault.signAptosSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test");preconditionFailure("Locked signed") }
        catch { check(error as? OathWalletError == .locked,"Lock prevents stale multisig authorization") }
        await session.unlock(pin)
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.aptosMultisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.aptosMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let draft = OathMultisigDraft(); draft.chain = .aptos; draft.resize(32)
        check(draft.slots.count == 32, "Aptos allows thirty-two signers")
        draft.resize(33); check(draft.slots.count == 32, "Aptos rejects thirty-three signers")
        draft.changeSource(.wif, at: 0); draft.slots[0].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 0)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[0].aptosMaterial == signers[0] && draft.slots[0].input.isEmpty, "Aptos raw key validates and clears input")
        draft.changeSource(.wif, at: 1); draft.slots[1].input = String(repeating: "16", count: 32)
        draft.prepareKey(at: 1)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[1].notice == .multisigDuplicateKey && draft.slots[1].aptosMaterial == nil, "Duplicate signer rejected")
        draft.clear(); check(draft.slots.allSatisfy { $0.aptosMaterial == nil }, "Clear drops signer material")
        draft.resize(2)
        for i in 0..<2 {
            draft.changeSource(.wif, at: i)
            draft.slots[i].input = "ed25519-priv-0x" + String(repeating: i == 0 ? "16" : "17", count: 32)
            draft.prepareKey(at: i)
            for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        check(draft.ready, "AIP-80 signer inputs prepare the threshold wallet")
        var finished: BackupWallet.AptosMultisig?
        draft.finishAptos { finished = $0 }
        for _ in 0..<1000 where draft.preparing { try await Task.sleep(for: .milliseconds(10)) }
        check(finished?.required == 2 && finished?.signers.count == 2, "Creation returns the complete threshold bundle")
        check(try finished?.policy().address == finished?.address, "Creation address is bound to canonical signer policy")
        draft.clear()
        print("Passed \(checks) Aptos raw-key host integration checks: draft, limits, passcode, encrypted vault, lock/unlock and encrypted backup restore. WalletCore HD derivation and live network transfers are separate checks.")
    }
}
