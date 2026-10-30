import Foundation
import OathAnkr
import OathCloudBackup
import OathDatabase

@main struct CheckSolanaMultisig {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        // Deterministic unfunded fixture keys, never used for real funds.
        let bootstrapKey = Data(repeating: 21, count: 32)
        let signerKeys = [Data(repeating: 22, count: 32), Data(repeating: 23, count: 32), Data(repeating: 24, count: 32)]
        let signers = try signerKeys.map { try BackupWallet.SolanaMultisig.Signer(address: SolanaSendCrypto.address(privateKey: $0), key: $0) }
        let address = try SolanaMultisigPolicy(createKey: SolanaSendCrypto.address(privateKey: bootstrapKey), required: 2, members: signers.map(\.address)).vault
        let material = BackupWallet.SolanaMultisig(required: 2, createSeed: bootstrapKey, address: address, signers: signers)
        try material.validateMaterial()
        check(try material.policy().required == 2, "Policy retains threshold")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathSolanaMultisig-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,4,1,7,2,6]
        try await OathWalletSetupStore(vault: vault, phrase: nil, solanaMultisig: material).save(pin)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        check(session.isUnlocked && !session.presentsOnboarding, "Successful passcode commit navigates to the wallet")
        check(session.portfolio?.wallet.kind == "solanaMultisig" && session.portfolio?.accounts.count == 1, "Wallet is Solana-only with its own settings identity")
        check(session.portfolio?.accounts.first?.address == address, "Committed public address matches policy")
        let raw = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: raw)
        check(envelope.version == 13, "New encrypted format requires multisig-aware reader")
        let contents = try envelope.openContents(using: envelope.key(for: pin))
        check(contents.wallets[0].solanaMultisig == material && contents.lifecycleVersion == 1, "Every signer survives vault encryption")
        check(raw.range(of: bootstrapKey) == nil && raw.range(of: signerKeys[0]) == nil, "Ciphertext contains no plaintext recovery material")
        do { _ = try envelope.openContents(using: envelope.key(for: [0,0,0,0,0,0])); preconditionFailure("Wrong passcode accepted") }
        catch { check(true, "Wrong passcode rejected") }
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.portfolio?.accounts.first?.address == address, "Lock and unlock preserve wallet and address")
        let disclosed = try await vault.recoveryMaterial(walletID: contents.wallets[0].id.uuidString, digits: pin)
        check(disclosed.solanaMultisig == material && disclosed.words.isEmpty, "Freshly authorized disclosure returns the entire multisig bundle")
        let backupData = try await vault.encryptedCloudBackup(walletID: contents.wallets[0].id.uuidString, password: "fixture-password")
        let restored = try OathRestoredWallet(backup: BackupDocument.open(backupData, password: "fixture-password"))
        check(restored.profile.addresses.first?.address == address && restored.secret.solanaMultisig == material, "Encrypted backup restores the exact policy and address")
        try await session.restoreWallet(restored)
        check(session.wallets.count == 1, "Restoring the same multisig wallet is idempotent")
        let profile = try await vault.unlockedProfile(), account = try await db.accounts(walletID:profile.id.uuidString).first!
        let policy = try material.policy()
        let plan = SolanaSendPlan(network:.mainnet,sender:address,recipient:signers[0].address,requestedAmount:1000000,amount:1000000,assetBalance:100000000,nativeBalance:100000000,blockhash:policy.createKey,lastValidBlockHeight:100,slot:10,transactionFee:15000,multisig:.init(policy:policy,index:1,payerBalance:100000000,storageRent:10000000,feePayer:policy.members.last))
        let quote = OathSolanaQuote(walletID:profile.id.uuidString,accountID:account.id,assetID:"solana:native",plan:plan),sendID=UUID().uuidString
        let now=Date.now.timeIntervalSince1970
        try await db.saveDraft(.init(id:sendID,walletID:quote.walletID,accountID:account.id,networkID:"solana",assetID:quote.assetID,idempotencyKey:sendID,recipient:plan.recipient,amountAtomic:String(plan.amount),state:"draft",createdAt:now,updatedAt:now))
        try await db.queueSolanaSend(sendID:sendID,plan:plan)
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:[9,9,9,9,9,9],reason:"Test");preconditionFailure("Wrong passcode signed multisig") }
        catch { check(error as? OathWalletError == .wrongPasscode,"Multisig signing requires the correct passcode") }
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:nil,reason:"Test");preconditionFailure("Missing biometrics signed multisig") }
        catch { check(error is OathBiometricCredentialError,"Biometric unavailability returns passcode fallback") }
        let signed = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:pin,reason:"Test")
        try SolanaSendCrypto.verify(signed,plan:plan)
        check(signed.preparations?.count == 1,"Authenticated wallet signing produces both exact stages")
        try await db.journalSolanaSignature(sendID:sendID,signed:signed)
        await session.lock()
        do { _ = try await vault.signSolanaSend(sendID:sendID,quote:quote,digits:pin,reason:"Test");preconditionFailure("Locked wallet signed") }
        catch { check(error as? OathWalletError == .locked,"Lock invalidates multisig signing") }
        await session.unlock(pin)
        let draft = OathMultisigDraft(); draft.chain = .solana; draft.resize(5)
        check(draft.slots.count == 5, "Solana allows five signers")
        draft.resize(6); check(draft.slots.count == 5, "Solana rejects six signers")
        // Public BIP39 fixture with an optional passphrase, independently derived.
        let phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about"
        let imported = try BackupWallet.SolanaMultisig.Signer.phrase(phrase, passphrase: "TREZOR")
        let phraseKey = try imported.signingKey()
        check(imported.address == "7zSmbu6gKkb6HB7UDPtHYjwCWuBHU1D4TpNZFm4sndQe", "Independent BIP39 passphrase derivation matches")
        check(phraseKey.count == 32, "BIP39 and SLIP-0010 produce an Ed25519 signer")
        draft.changeSource(.phrase, at: 0); draft.slots[0].input = phrase; draft.slots[0].passphrase = "TREZOR"
        draft.prepareKey(at: 0)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[0].solanaMaterial == imported && draft.slots[0].input.isEmpty, "Phrase import validates and clears input")
        draft.changeSource(.phrase, at: 1); draft.slots[1].input = phrase; draft.slots[1].passphrase = "TREZOR"
        draft.prepareKey(at: 1)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[1].notice == .multisigDuplicateKey && draft.slots[1].solanaMaterial == nil, "Duplicate signer rejected")
        draft.changeSource(.wif, at: 2)
        draft.slots[2].input = try SolanaSendCrypto.encode(signerKeys[0] + SolanaSendCrypto.publicKey(privateKey: signerKeys[0]))
        draft.prepareKey(at: 2)
        for _ in 0..<1000 where draft.working != nil { try await Task.sleep(for: .milliseconds(10)) }
        check(draft.slots[2].solanaMaterial?.key == signerKeys[0], "Native keypair import validates and preserves the signer")
        draft.clear(); check(draft.slots.allSatisfy { $0.solanaMaterial == nil }, "Clear drops signer material")
        // Additional creation must preserve the existing vault and app lock.
        let additionalSeed = Data(repeating: 25, count: 32)
        let additionalPolicy = try SolanaMultisigPolicy(createKey: SolanaSendCrypto.address(privateKey: additionalSeed), required: 2, members: signers.map(\.address))
        let additional = BackupWallet.SolanaMultisig(required: 2, createSeed: additionalSeed, address: try additionalPolicy.vault, signers: signers)
        let requestID = UUID()
        let addedID = try await session.addWallet(requestID: requestID, multisig: .solana(additional))
        check(addedID == requestID.uuidString && session.wallets.count == 2, "Additional multisig creation preserves existing wallets")
        check(session.pendingCustomizationID == addedID, "Additional multisig opens customization")
        let retriedID = try await session.addWallet(requestID: requestID, multisig: .solana(additional))
        check(retriedID == addedID && session.wallets.count == 2, "Retry does not duplicate the multisig wallet")
        do {
            _ = try await session.addWallet(requestID: requestID, multisig: .solana(material))
            preconditionFailure("Different material reused a creation request")
        } catch { check(error as? OathWalletError == .invalidPrivateKey, "Request ID cannot replace existing signer material") }
        let updatedEnvelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let preserved = try updatedEnvelope.openContents(using: updatedEnvelope.key(for: pin))
        check(preserved.wallets.count == 2 && preserved.wallets.contains { $0.solanaMultisig == material }, "Original recovery material survives additional creation")
        check(updatedEnvelope.salt == envelope.salt && updatedEnvelope.biometricAccess == envelope.biometricAccess, "App passcode and biometric configuration are preserved")
        await session.lock()
        do {
            _ = try await session.addWallet(requestID: UUID(), multisig: .solana(additional))
            preconditionFailure("Locked app added a multisig wallet")
        } catch { check(error as? OathWalletError == .locked, "Additional multisig creation requires an unlocked app") }
        await session.unlock(pin)
        check(session.isUnlocked && session.wallets.count == 2, "Existing passcode unlocks both wallets")
        print("Passed \(checks) Solana host integration checks: draft, limits, passcode, encrypted vault, lock/unlock and encrypted backup restore. WalletCore BIP39 uses a host KDF substitute; live network transfers are separate checks.")
    }
}
