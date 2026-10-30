import Foundation
import CryptoKit
import OathCloudBackup
import OathDatabase

extension CheckMultiWallet {
    /// Real encrypted persistence, SQL and UI state machines; only chain
    /// derivation is the Mac harness's explicitly synthetic implementation.
    @MainActor static func checkPassphraseWallets() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<1_000 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("Passphrase fixture timed out")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathPassphrase-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8, 6, 2, 9, 1, 4], nextPIN: [UInt8] = [4, 1, 9, 2, 6, 8]
        let phrase = OathValidatedMnemonic(phrase: "synthetic passphrase fixture", language: "english")
        try await vault.create(digits: pin, importing: phrase)
        await biometrics.enroll(try await vault.biometricCredential())
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let root = session.displayedProfile!.id
        try await session.customizeWallet(root.uuidString, name: "Original", colorHex: "209750")
        session.finishInitialCustomization()
        let original = session.displayedProfile
        let originalRows = try await db.snapshot(walletID: root.uuidString, currency: "USD")
        let request = UUID(), input = "  TéST 🔑  "
        let canonical = try RecoveryPassphrase.normalized(input)
        let added = try await session.addPassphraseWallet(sourceID: root.uuidString, passphrase: input, requestID: request)
        check(added == request.uuidString && session.wallets.count == 2, "Passphrase must add and select a separate member")
        check(session.portfolio?.wallet.nameIndex == 1 && session.portfolio?.wallet.nameGroup == "passphrase"
              && session.portfolio?.wallet.parentWalletID == root.uuidString, "First passphrase wallet keeps its source and number")
        check(session.pendingCustomizationID == added && !session.presentsOnboarding,
              "A new passphrase wallet goes to Customize without new app-lock setup")
        check(session.portfolio?.wallet.kind == "passphrase" && session.portfolio?.wallet.backedUp == false,
              "SQL must identify passphrase wallets without claiming a backup")
        check(session.portfolio?.accounts.count == OathImportChain.allCases.count, "Passphrase wallet commits all supported chains")
        let unchanged = try await db.snapshot(walletID: root.uuidString, currency: "USD")
        check(unchanged.wallet == originalRows.wallet && unchanged.accounts == originalRows.accounts,
              "Adding a passphrase must not alter the original name, artwork or accounts")

        let bytes = try storage.read("vault-v1")!
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: bytes)
        let key = try envelope.key(for: pin)
        let contents = try envelope.openContents(using: key)
        check(envelope.version == 4, "Old apps must reject the new secret format")
        check(contents.wallets.first?.passphrase == nil && contents.wallets.last?.passphrase == canonical,
              "Only the added member receives the canonical passphrase")
        check(contents.wallets.allSatisfy { $0.mnemonic == phrase.phrase }, "Original recovery words are shared exactly")
        check(!String(decoding: bytes, as: UTF8.self).contains(canonical), "Envelope cannot contain a plaintext passphrase")
        let metadata = try JSONEncoder().encode(session.wallets)
        check(!String(decoding: metadata, as: UTF8.self).contains(canonical), "Wallet list metadata cannot contain a passphrase")
        for version in [2, 3] {
            let downgraded = OathVaultEnvelope(version: version, id: envelope.id, salt: envelope.salt,
                iterations: envelope.iterations, sealed: envelope.sealed, walletIDs: envelope.walletIDs,
                protection: envelope.protection, biometricAccess: envelope.biometricAccess)
            do { _ = try downgraded.openContents(using: key); preconditionFailure("Vault downgrade succeeded") }
            catch { check(true, "Passphrase format is authenticated, including its version") }
        }
        let single = try OathVaultEnvelope.seal(contents.wallets.last!, key: key, salt: envelope.salt, iterations: envelope.iterations)
        let singleSecret = try single.open(using: key)
        check(single.version == 4 && singleSecret.passphrase == canonical,
              "Single-member envelope API cannot accidentally write passphrase material as legacy v1")

        let attempts = DerivationGate.shared.count
        let retried = try await session.addPassphraseWallet(sourceID: root.uuidString, passphrase: canonical, requestID: request)
        check(retried == added && session.wallets.count == 2 && DerivationGate.shared.count == attempts,
              "Retrying a committed request neither derives again nor duplicates it")
        do {
            _ = try await session.addPassphraseWallet(sourceID: request.uuidString, passphrase: canonical, requestID: UUID())
            preconditionFailure("Equivalent passphrase duplicated a wallet")
        } catch {
            check(error as? OathWalletError == .duplicatePassphraseWallet(request),
                  "Equivalent Unicode from either source must point to the same existing wallet")
        }
        let third = try await session.addPassphraseWallet(sourceID: added, passphrase: "tést 🔑", requestID: UUID())
        check(third != added && session.wallets.count == 3, "Case and spaces must remain significant")
        check(session.portfolio?.wallet.nameIndex == 2 && session.portfolio?.wallet.parentWalletID == added,
              "A wallet created from a passphrase wallet keeps that direct parent and the next number")
        let tree = WalletTree(session.wallets)
        check(tree.roots.count == 1 && tree.roots[0].children[0].children[0].id == third,
              "Both wallet list surfaces can render the same nested family")
        let descendant = try await vault.recoveryMaterial(walletID: third, digits: pin)
        check(descendant.words == OathMnemonicValidator.words(in: phrase.phrase)
              && descendant.passphrase == "tést 🔑".decomposedStringWithCompatibilityMapping,
              "Adding from a passphrase wallet replaces the derivation passphrase, never concatenates it")
        let baseImport = try await session.addWallet(requestID: UUID(), importing: phrase)
        check(baseImport == root.uuidString && session.displayedProfile == original,
              "Importing bare words must select the base wallet, never a passphrase member")
        for index in 0..<24 {
            _ = try await session.addPassphraseWallet(sourceID: root.uuidString,
                passphrase: "synthetic variant \(index)", requestID: UUID())
        }
        check(session.wallets.count == 27, "Multiple passphrases cannot be constrained by an arbitrary wallet-count cap")

        try await session.customizeWallet(added, name: "Travel", colorHex: "DF438D")
        let portable = try await vault.encryptedCloudBackup(walletID: added, password: "synthetic-backup-password")
        let restored = try BackupDocument.open(portable, password: "synthetic-backup-password")
        check(restored.passphrase == canonical && restored.mnemonic == phrase.phrase,
              "The encrypted backup must include both required parts of recovery material")
        check(restored.name == "Travel" && restored.colorHex == "DF438D", "Backup retains member-specific customization")
        check(restored.parentWalletID == root, "Portable backup preserves optional parent provenance")
        let baseBackup = try await vault.encryptedCloudBackup(walletID: root.uuidString, password: "synthetic-backup-password")
        check(try BackupDocument.open(baseBackup, password: "synthetic-backup-password").passphrase == nil,
              "Original wallet backup must not include another wallet's passphrase")
        let oldReads = await biometrics.reads
        let material = try await vault.recoveryMaterialWithBiometrics(walletID: added, reason: "Synthetic test")
        let newReads = await biometrics.reads
        check(material.passphrase == canonical && newReads == oldReads + 1,
              "Viewing an inactive passphrase member must require fresh Face ID")
        let disclosure = OathRecoveryPhraseModel(walletID: added, reader: vault)
        disclosure.acknowledge(reason: "Synthetic test")
        try await wait { !disclosure.busy }
        check(disclosure.phase == .revealed && disclosure.passphrase == canonical, "Authenticated recovery shows passphrase with words")
        disclosure.cancelAuthentication()
        check(disclosure.phase == .warning && disclosure.passphrase == nil && disclosure.words.isEmpty,
              "Backgrounding clears both parts of revealed recovery material")

        let beforeFailure = try storage.read("vault-v1")
        storage.rejectNextUpdate()
        let failedID = UUID()
        do {
            _ = try await session.addPassphraseWallet(sourceID: added, passphrase: "retry fixture", requestID: failedID)
            preconditionFailure("Injected storage failure ignored")
        } catch { check(session.isUnlocked && !session.changingWallet, "Failed commit leaves session usable") }
        check(try storage.read("vault-v1") == beforeFailure, "Failed protected write must retain original ciphertext")
        check(try await db.wallet(failedID.uuidString) == nil, "Failed protected write cannot leave orphan public accounts")
        _ = try await session.addPassphraseWallet(sourceID: added, passphrase: "retry fixture", requestID: failedID)
        check(session.wallets.count == 28 && session.displayedProfile?.id == failedID, "Failed write can be retried exactly once")

        let interruptedID = UUID()
        try await db.importWalletIfNeeded(WalletRecord(id: interruptedID.uuidString, name: "Conflict", kind: "watchOnly",
            vaultReference: "foreign", createdAt: 0), accounts: [])
        do {
            _ = try await session.addPassphraseWallet(sourceID: added, passphrase: "interrupted fixture", requestID: interruptedID)
            preconditionFailure("Injected metadata conflict ignored")
        } catch { check(session.displayedProfile?.id == failedID, "Metadata failure must not select conflicting accounts") }
        try await db.deleteWalletMetadata(interruptedID.uuidString)
        _ = try await session.addPassphraseWallet(sourceID: added, passphrase: "interrupted fixture", requestID: interruptedID)
        check(session.wallets.count == 29 && session.pendingCustomizationID == interruptedID.uuidString,
              "A post-commit retry recovers the same encrypted member and its customization step")

        let countBeforeCancel = session.wallets.count
        let cancelledID = UUID()
        DerivationGate.shared.arm()
        let pending = Task { try await session.addPassphraseWallet(sourceID: added, passphrase: "cancel fixture", requestID: cancelledID) }
        try await wait { DerivationGate.shared.isWaiting }
        check(session.changingWallet, "Expensive derivation must not block the UI actor")
        await session.lock()
        DerivationGate.shared.release()
        do { _ = try await pending.value; preconditionFailure("Background cancellation committed") }
        catch { check(error is CancellationError, "Lock must cancel a pending passphrase commit") }
        await session.unlock(pin)
        check(session.wallets.count == countBeforeCancel && !session.wallets.contains { $0.id == cancelledID.uuidString },
              "Late derivation cannot append a wallet after locking")

        let model = OathPassphraseWalletModel(sourceID: added, session: session)
        check(!model.canSubmit && !model.busy, "Empty passphrase cannot accidentally reopen the base wallet")
        model.passphrase = "Form fixture"; model.confirmation = "form fixture"
        check(!model.canSubmit && model.validationNotice == .passphraseMismatch, "Confirmation preserves case")
        model.confirmation = model.passphrase
        model.prepareSubmission(); model.prepareSubmission()
        check(model.busy && model.dismissingKeyboard && !session.changingWallet,
              "Submit waits for keyboard dismissal before beginning work")
        model.keyboardDismissed(); model.keyboardDismissed()
        try await wait { !model.busy }
        check(model.createdWalletID != nil && session.wallets.count == countBeforeCancel + 1,
              "Repeated button or keyboard callbacks create one member")
        check(model.passphrase.isEmpty && model.confirmation.isEmpty, "Successful creation clears the screen draft")
        model.cancel()
        model.passphrase = input; model.confirmation = canonical
        model.prepareSubmission(); model.keyboardDismissed()
        try await wait { !model.busy }
        check(model.duplicateWalletID == request && model.notice == .passphraseAlreadyExists,
              "Form offers the existing member instead of silently duplicating it")
        model.cancel()
        model.passphrase = "Cancelled draft"; model.confirmation = model.passphrase
        model.prepareSubmission(); model.cancel(); model.keyboardDismissed()
        check(!model.busy && model.passphrase.isEmpty && !model.dismissingKeyboard,
              "Closing during keyboard dismissal clears the draft and cannot start derivation")
        let countBeforeLeaving = session.wallets.count
        model.passphrase = "Leave during derivation"; model.confirmation = model.passphrase
        DerivationGate.shared.arm()
        model.prepareSubmission(); model.keyboardDismissed()
        try await wait { DerivationGate.shared.isWaiting }
        model.cancel()
        DerivationGate.shared.release()
        try await wait { !session.changingWallet }
        check(session.isUnlocked && session.wallets.count == countBeforeLeaving,
              "Leaving an editor must cancel before commit without unnecessarily locking the app")
        check(model.passphrase.isEmpty && model.createdWalletID == nil,
              "A late cancelled creation cannot repopulate the draft or push customization")

        let keyID = try await session.addWallet(requestID: UUID(), privateKey: .init(bytes: Data(repeating: 9, count: 32), networks: [.ethereum]))
        do {
            _ = try await session.addPassphraseWallet(sourceID: keyID, passphrase: "unsupported", requestID: UUID())
            preconditionFailure("Private key accepted BIP-39 passphrase")
        } catch { check(error as? OathWalletError == .unavailable, "Private-key wallets cannot create mnemonic-passphrase wallets") }
        for invalid in ["", "before\0after", String(repeating: "x", count: 257)] {
            do {
                _ = try await session.addPassphraseWallet(sourceID: added, passphrase: invalid, requestID: UUID())
                preconditionFailure("Invalid passphrase accepted")
            } catch { check(error is RecoveryPassphraseError, "Invalid input fails before derivation or persistence") }
        }

        try await session.selectWallet(request)
        let finalIDs = Set(session.wallets.map(\.id))
        await session.lock()
        let reopenedVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: try await OathDatabase.open(at: url))
        let reopened = OathWalletSession(vault: reopenedVault)
        await reopened.load()
        check(reopened.isLocked && reopened.displayedProfile?.id == request, "Cold launch keeps passphrase member selected under lock")
        await reopened.unlockWithBiometrics(automatically: true)
        check(reopened.isUnlocked && Set(reopened.wallets.map(\.id)) == finalIDs,
              "Original Face ID enrollment opens every member after a cold restart")
        let authorization = try await reopenedVault.authorizeSecurityChange(digits: pin)
        try await reopenedVault.setPasscode(nextPIN, authorization: authorization)
        check(try await reopenedVault.recoveryMaterial(walletID: added, digits: nextPIN).passphrase == canonical,
              "Changing the app PIN must preserve the independent wallet passphrase")
        let disable = try await reopenedVault.authorizeSecurityChange(digits: nextPIN)
        try await reopenedVault.setPasscode(nil, authorization: disable)
        let unlocked = try await reopenedVault.recoveryMaterialWithBiometrics(walletID: added, reason: "Synthetic test")
        check(unlocked.passphrase == canonical, "Disabling app security must preserve encrypted passphrase wallet material")
        let finalEnvelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        check(finalEnvelope.version == 4 && !finalEnvelope.passcodeEnabled,
              "Protection changes must not downgrade the passphrase format")
        await reopened.lock()
        checks += try await checkPassphraseTreeLifecycle()
        checks += try await checkDeletedPassphraseRecreation()
        print("Passed \(checks) passphrase persistence, backup and flow checks.")
        return checks
    }

    @MainActor static func checkDeletedPassphraseRecreation() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathPassphraseRestore-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory()
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [8, 6, 2, 9, 1, 4]
        try await vault.create(digits: pin, importing: .init(phrase: "synthetic retained passphrase fixture", language: "english"))
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let root = session.displayedProfile!.id.uuidString
        let request = UUID(), input = "  TéST 🔑  "
        let canonical = try RecoveryPassphrase.normalized(input)
        let child = try await session.addPassphraseWallet(sourceID: root, passphrase: input, requestID: request)
        try await session.customizeWallet(child, name: "Travel", colorHex: "DF438D")
        let original = try await db.snapshot(walletID: child, currency: "USD")

        // Cover a fresh form submission and retrying the original creation request.
        for retryOriginalRequest in [false, true] {
            let beforeRemoval = try await db.snapshot(walletID: child, currency: "USD")
            let removal = OathWalletRemovalAction(ids: [child], permanently: false)
            let authorization = try await vault.authorizeWalletRemoval(removal, digits: pin, reason: "Synthetic restoration check")
            try await session.removeWallets(removal, authorization: authorization)
            check(session.recentlyDeletedWallets.map(\.id) == [child] && session.wallets.map(\.id) == [root],
                  "Fixture moves passphrase wallet into Recently Deleted")
            let before = try storage.read("vault-v1")
            storage.rejectNextUpdate()
            do {
                _ = try await session.addPassphraseWallet(sourceID: root, passphrase: canonical,
                                                        requestID: retryOriginalRequest ? request : UUID())
                preconditionFailure("Rejected restoration write was ignored")
            } catch {
                check(error as? OathWalletError == .unavailable, "Restoration reaches protected storage instead of rejecting a retained duplicate")
            }
            check(try storage.read("vault-v1") == before && session.recentlyDeletedWallets.map(\.id) == [child],
                  "Failed restoration keeps encrypted and visible deletion state intact")

            if retryOriginalRequest {
                let restored = try await session.addPassphraseWallet(sourceID: root, passphrase: canonical, requestID: request)
                check(restored == child, "Retry restores the original identity")
            } else {
                let model = OathPassphraseWalletModel(sourceID: root, session: session)
                model.passphrase = canonical; model.confirmation = input
                model.prepareSubmission(); model.keyboardDismissed()
                for _ in 0..<1_000 {
                    if !model.busy { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
                check(!model.busy && model.createdWalletID == child && model.notice == nil && model.duplicateWalletID == nil,
                      "Normal creation form continues successfully with the restored wallet")
                check(model.passphrase.isEmpty && model.confirmation.isEmpty, "Successful restoration clears the form secrets")
            }
            check(session.recentlyDeletedWallets.isEmpty && Set(session.wallets.map(\.id)) == [root, child]
                  && session.displayedProfile?.id.uuidString == child, "Restoration selects one active wallet and clears Recently Deleted")
            let restored = try await db.snapshot(walletID: child, currency: "USD")
            // Removal and restoration each invalidate outstanding sync tickets;
            // account identity and every other saved field must remain intact.
            let expectedAccounts = beforeRemoval.accounts.map { account in
                var expected = account
                expected.syncGeneration += 2
                return expected
            }
            check(restored.wallet == original.wallet && restored.accounts == expectedAccounts,
                  "Restoration preserves account identity, customization, family and wallet number")
            let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
            let contents = try envelope.openContents(using: envelope.key(for: pin))
            check(contents.wallets.count == 2 && contents.wallets.first { $0.id.uuidString == child }?.deletedAt == nil
                  && contents.lastPassphraseIndex == 1, "Encrypted membership restores without allocating another wallet or ordinal")
            await session.lock(); await session.unlock(pin)
            check(session.isUnlocked && session.recentlyDeletedWallets.isEmpty && session.displayedProfile?.id.uuidString == child,
                  "Restored membership and selection survive reloading encrypted storage")
            do {
                _ = try await session.addPassphraseWallet(sourceID: root, passphrase: canonical, requestID: UUID())
                preconditionFailure("Active duplicate accepted")
            } catch {
                check(error as? OathWalletError == .duplicatePassphraseWallet(request), "An already active wallet retains duplicate protection")
            }
        }
        await session.lock()
        return checks
    }


    @MainActor static func checkPassphraseTreeLifecycle() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathFamily-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [8,6,2,9,1,4]
        try await vault.create(digits: pin, importing: .init(phrase: "synthetic wallet family fixture", language: "english"))
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let root = session.displayedProfile!.id.uuidString
        let first = try await session.addPassphraseWallet(sourceID: root, passphrase: "synthetic first", requestID: UUID())
        let second = try await session.addPassphraseWallet(sourceID: root, passphrase: "synthetic second", requestID: UUID())
        try await session.customizeWallet(first, name: "Travel", colorHex: "DF438D")
        try await session.reorderWallets(WalletTree(session.wallets).moving([0], to: 2, parentID: root))
        check(WalletTree(session.wallets).roots[0].children.map(\.id) == [second, first], "Reordering siblings preserves their family")

        // Old builds saved no provenance. Upgrade infers only an unambiguous
        // original from encrypted material, preserves custom labels and saves it.
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let key = try envelope.key(for: pin)
        var old = try envelope.openContents(using: key)
        for index in old.wallets.indices { old.wallets[index].parentWalletID = nil; old.wallets[index].passphraseIndex = nil }
        old.lastPassphraseIndex = nil
        let oldEnvelope = try OathVaultEnvelope.seal(old, rootID: envelope.id, key: key, salt: envelope.salt,
            iterations: envelope.iterations, protection: envelope.protection, biometricAccess: envelope.biometricAccess)
        await session.lock()
        try storage.update(JSONEncoder().encode(oldEnvelope), account: "vault-v1")
        await session.unlock(pin)
        check(session.isUnlocked && session.wallets.filter { $0.kind == "passphrase" }.allSatisfy { $0.parentWalletID == root },
              "Authenticated legacy upgrade restores the original family")
        check(session.wallets.first { $0.id == first }?.name == "Travel", "Upgrade preserves custom names")
        let upgraded = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!).openContents(using: key)
        check(upgraded.wallets.filter { $0.passphrase != nil }.allSatisfy { $0.passphraseIndex != nil && $0.parentWalletID != nil },
              "Upgrade persists family and numbering in ciphertext")

        let childRemoval = OathWalletRemovalAction(ids: [first], permanently: false)
        let childAuth = try await vault.authorizeWalletRemoval(childRemoval, digits: pin, reason: "Synthetic family check")
        try await session.removeWallets(childRemoval, authorization: childAuth)
        check(Set(session.wallets.map(\.id)) == [root, second], "Removing a child preserves its parent and sibling")
        try await session.recoverDeletedWallets([first])
        check(WalletTree(session.wallets).roots.count == 1, "Restoring a child returns it to its family")
        let parentRemoval = OathWalletRemovalAction(ids: [root], permanently: false)
        let parentAuth = try await vault.authorizeWalletRemoval(parentRemoval, digits: pin, reason: "Synthetic family check")
        try await session.removeWallets(parentRemoval, authorization: parentAuth)
        check(Set(WalletTree(session.wallets).roots.map(\.id)) == [first, second], "Removing only the parent keeps both children accessible")
        try await session.selectWallet(UUID(uuidString: first)!)
        check(session.portfolio?.wallet.name == "Travel", "Child still selects its independent settings and identity")
        try await session.recoverDeletedWallets([root])
        check(WalletTree(session.wallets).roots[0].children.count == 2, "Restoring parent regroups existing children")

        // Public metadata loss cannot change the saved ordinal or provenance.
        try await db.deleteWalletMetadata(second)
        await session.lock(); await session.unlock(pin)
        check(session.wallets.first { $0.id == second }?.nameIndex == 2
              && session.wallets.first { $0.id == second }?.parentWalletID == root,
              "SQL repair restores the encrypted number and parent")
        let soft = OathWalletRemovalAction(ids: [second], permanently: false)
        let softAuth = try await vault.authorizeWalletRemoval(soft, digits: pin, reason: "Synthetic family check")
        try await session.removeWallets(soft, authorization: softAuth)
        let hard = OathWalletRemovalAction(ids: [second], permanently: true)
        let hardAuth = try await vault.authorizeWalletRemoval(hard, digits: pin, reason: "Synthetic family check")
        try await session.removeWallets(hard, authorization: hardAuth)
        let third = try await session.addPassphraseWallet(sourceID: first, passphrase: "synthetic third", requestID: UUID())
        check(session.portfolio?.wallet.nameIndex == 3 && session.portfolio?.wallet.parentWalletID == first,
              "Permanent deletion never reuses a passphrase number")
        await session.lock(); await session.unlock(pin)
        check(session.displayedProfile?.id.uuidString == third && WalletTree(session.wallets).roots[0].children[0].children[0].id == third,
              "Nested child remains selected and grouped after restart")
        await session.lock()
        return checks
    }
}
