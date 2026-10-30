import Foundation
import OathAnkr
import OathCloudBackup
import OathDatabase

@main struct CheckXrplMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Deterministic unfunded fixture keys, never used for real funds.
        let bootstrapKey = Data(repeating: 21, count: 32)
        let signerKeys = [Data(repeating: 22, count: 32), Data(repeating: 23, count: 32), Data(repeating: 24, count: 32)]
        let signers = try signerKeys.map { try BackupWallet.XrplMultisig.Signer(address: XrplSendCrypto.address(privateKey: $0), key: $0) }
        let address = try XrplSendCrypto.address(privateKey: bootstrapKey)
        let material = BackupWallet.XrplMultisig(required: 2, accountKey: bootstrapKey, address: address, signers: signers)
        try material.validateMaterial()
        check(try material.policy().required == 2, "Policy retains threshold")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathXrplMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, xrplMultisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "xrplMultisig" && session.portfolio?.accounts.count == 1, "Wallet is XRP-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 14, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].xrplMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: bootstrapKey) == nil && raw.range(of: signerKeys[0]) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let account = try await db.accounts(walletID:contents.wallets[0].id.uuidString).first!
        let policy = try material.policy()
        let plan = XrplSendPlan(network:.mainnet,sender:address,recipient:"rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",reference:"native",
            requestedAmount:"1000000",amount:"1000000",assetDebit:"1000000",assetBalance:"100000000",nativeBalance:100000000,
            reserve:1200000,fee:36,sequence:42,firstLedger:100,lastLedger:120,multisig:policy)
        let quote = OathXrplQuote(walletID:account.walletID,accountID:account.id,assetID:"xrpl:native",plan:plan)
        let now = Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:"multisig-send",walletID:quote.walletID,accountID:account.id,networkID:"xrpl",assetID:quote.assetID,idempotencyKey:"multisig-send",recipient:plan.recipient,amountAtomic:plan.amount,state:"draft",createdAt:now,updatedAt:now))
        try await db.queueXrplSend(sendID:"multisig-send",plan:plan)
        do { _ = try await vault.signXrplSend(sendID:"multisig-send",quote:quote,digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong PIN signed") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Wrong PIN cannot authorize multisig") }
        do { _ = try await vault.signXrplSend(sendID:"multisig-send",quote:quote,digits:nil,reason:"Test");preconditionFailure("Missing biometrics signed") }
        catch { check(error is OathBiometricCredentialError,"Missing biometrics requires PIN fallback") }
        let signed = try await vault.signXrplSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test")
        try XrplSendCrypto.verify(signed,plan:plan)
        check(signed.signers?.count == 2,"Freshly authenticated vault signs with exact quorum")
        try await db.journalXrplSignature(sendID:"multisig-send",signed:signed)
        let journal = try await db.send("multisig-send")
        check(journal?.state == "signed" && journal?.signedPayload != nil,"Exact signatures persisted before broadcast")
        check(try await db.xrplSendPlan(sendID:"multisig-send") == plan,"Recovery preserves exact policy and intent")
        await session.lock()
        do { _ = try await vault.signXrplSend(sendID:"multisig-send",quote:quote,digits:pin,reason:"Test");preconditionFailure("Locked signed") }
        catch { check(error as? OathWalletError == .locked,"Lock prevents stale multisig authorization") }
        await session.unlock(pin)
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.xrplMultisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.xrplMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let draft = OathMultisigDraft(); draft.chain = .xrpl; draft.resize(8)
        check(draft.slots.count == 8, "XRP allows eight signers")
        draft.resize(9); check(draft.slots.count == 8, "XRP rejects nine signers")
        draft.changeSource(.wif, at: 0); draft.slots[0].input = signerKeys[0].map { String(format: "%02x", $0) }.joined()
        draft.prepareKey(at: 0)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[0].xrplMaterial == signers[0] && draft.slots[0].input.isEmpty, "XRP raw key validates and clears input")
        draft.changeSource(.wif, at: 1); draft.slots[1].input = signerKeys[0].map { String(format: "%02x", $0) }.joined()
        draft.prepareKey(at: 1)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[1].notice == .multisigDuplicateKey && draft.slots[1].xrplMaterial == nil, "Duplicate signer rejected")
        draft.clear(); check(draft.slots.allSatisfy { $0.xrplMaterial == nil }, "Clear drops signer material")
        print("Passed \(checks) XRP raw-key host integration checks: draft, limits, passcode, encrypted vault, lock/unlock and encrypted backup restore. WalletCore HD derivation and live network transfers are separate checks.")
    }
}
