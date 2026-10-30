import Foundation
import CryptoKit
import OathDatabase
import OathCloudBackup
import SQLite3

extension CheckMultiWallet {
    @MainActor static func checkWalletLifecycle() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ message: String, _ operation: () async throws -> Void) async {
            do { try await operation(); preconditionFailure(message) } catch { checks += 1 }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
            preconditionFailure("Wallet lifecycle fixture timed out")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathLifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let resetEnvironment = LifecycleResetEnvironment()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: resetEnvironment)
        let pin: [UInt8] = [1, 2, 8, 4, 7, 3]
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let root = session.wallets[0].id
        try await session.customizeWallet(root, name: "Original fixture", colorHex: nil)
        session.finishInitialCustomization()
        let second = try await session.addWallet(requestID: UUID())
        try await session.customizeWallet(second, name: "Second fixture", colorHex: "DF438D")
        let third = try await session.addWallet(requestID: UUID())
        try await session.customizeWallet(third, name: "Third fixture", colorHex: nil)
        let originalOrdinals = Dictionary(uniqueKeysWithValues: session.wallets.map { ($0.id, $0.nameIndex) })
        try await session.reorderWallets([third, root, second])
        check(session.wallets.map(\.id) == [third, root, second], "Drag order must persist")
        check(try await db.wallets().map(\.id) == [third, root, second], "SQL order must match displayed order")
        check(Dictionary(uniqueKeysWithValues: session.wallets.map { ($0.id, $0.nameIndex) }) == originalOrdinals, "Reordering must not rename default wallets")
        check(session.displayedProfile?.id.uuidString == third, "Reordering must not change the selected wallet")
        await rejects("Duplicate reorder IDs must be rejected") { try await db.reorderWallets([root, root, second]) }
        await rejects("Incomplete reorder must be rejected") { try await db.reorderWallets([root, second]) }
        let soft = OathWalletRemovalAction(ids: [third], permanently: false)
        let hard = OathWalletRemovalAction(ids: [third], permanently: true)
        let model = OathWalletRemovalModel(session: session)
        var removedActions: [OathWalletRemovalAction] = []
        model.begin(soft, reason: "Synthetic removal")
        try await wait { model.phase == .passcode }
        check(try await db.wallet(third)?.deletedAt == nil, "Opening removal must not delete anything")
        model.submit([0,0,0,0,0,0]); try await wait { !model.busy }
        check(model.phase == .passcode && model.notice == .unlockIncorrect, "Wrong PIN cannot reach confirmation")
        model.submit(pin); try await wait { model.phase == .confirmation }
        check(try await db.wallet(third)?.deletedAt == nil, "Authentication alone cannot remove a wallet")
        model.cancel()
        check(session.wallets.count == 3, "Cancelling native confirmation preserves every wallet")
        model.confirm { removedActions.append($0) }
        check(removedActions.isEmpty, "Cancelled removal cannot navigate away from wallet settings")
        let now = ContinuousClock.now
        let expired = try await vault.authorizeWalletRemoval(soft, digits: pin, reason: "", now: now)
        await rejects("Expired removal authorization cannot be used") {
            _ = try await vault.removeWallets(soft, authorization: expired, clock: now.advanced(by: .seconds(121)))
        }
        let bound = try await vault.authorizeWalletRemoval(soft, digits: pin, reason: "")
        await rejects("Removal authorization cannot change wallets") {
            _ = try await vault.removeWallets(.init(ids: [second], permanently: false), authorization: bound)
        }
        await rejects("Removal authorization cannot escalate to permanent deletion") {
            _ = try await vault.removeWallets(hard, authorization: bound)
        }
        await vault.cancelWalletRemovalAuthorization(bound)
        await rejects("Cancelled authorization cannot be used") { _ = try await vault.removeWallets(soft, authorization: bound) }
        let locked = try await vault.authorizeWalletRemoval(soft, digits: pin, reason: "")
        await session.lock()
        await rejects("Lock revokes removal authorization") { _ = try await vault.removeWallets(soft, authorization: locked) }
        await session.unlock(pin)
        let rejected = try await vault.authorizeWalletRemoval(soft, digits: pin, reason: "")
        storage.rejectNextUpdate()
        await rejects("Rejected Keychain write must fail removal") { try await session.removeWallets(soft, authorization: rejected) }
        check(session.wallets.count == 3 && session.recentlyDeletedWallets.isEmpty, "Failed atomic write changes neither SQL nor visible membership")

        await biometrics.enroll(try await vault.biometricCredential())
        try await session.refreshSecurity()
        let reads = await biometrics.reads
        model.begin(soft, reason: "Synthetic removal")
        try await wait { model.phase == .confirmation }
        check(await biometrics.reads == reads + 1, "Face ID must run before native confirmation")
        model.cancel()
        await biometrics.pauseNextRead()
        model.begin(soft, reason: "Synthetic removal")
        for _ in 0..<500 { if await biometrics.isWaiting { break }; try await Task.sleep(for: .milliseconds(10)) }
        check(await biometrics.isWaiting, "Biometric fixture must be suspended")
        model.cancel(); await biometrics.releaseRead()
        try await Task.sleep(for: .milliseconds(30))
        check(model.phase == .idle && !model.busy, "Late Face ID cannot reopen cancelled removal")
        model.begin(soft, reason: "Synthetic removal")
        try await wait { model.phase == .confirmation }
        storage.rejectNextUpdate()
        model.confirm { removedActions.append($0) }
        try await wait { model.phase == .idle && !model.confirming }
        check(removedActions.isEmpty && model.notice == .walletRemovalFailed,
              "Failed removal keeps settings open and reports its failure")
        check(session.wallets.count == 3 && session.recentlyDeletedWallets.isEmpty,
              "Failed settings removal preserves wallet membership")
        model.begin(soft, reason: "Synthetic removal")
        try await wait { model.phase == .confirmation }
        model.confirm { action in
            check(model.phase == .idle && !model.confirming, "Success navigation runs after removal state clears")
            check(session.recentlyDeletedWallets.contains { $0.id == third },
                  "Success navigation runs only after Recently Deleted is updated")
            removedActions.append(action)
        }
        model.confirm { removedActions.append($0) }
        try await wait { model.phase == .idle && !model.confirming }
        check(removedActions == [soft], "Repeated confirmation cannot delete or navigate twice")
        check(session.wallets.map(\.id) == [root, second] && session.recentlyDeletedWallets.map(\.id) == [third], "Confirmed removal moves the selected wallet to Recently Deleted")
        check(session.displayedProfile?.id.uuidString == root, "Removing active wallet selects the first remaining wallet")
        try await session.reorderWallets([second, root])
        await session.lock(); await session.unlock(pin)
        check(session.displayedProfile?.id.uuidString == root, "Reordering after removal must preserve fallback selection across unlock")
        check(try await db.accounts(walletID: third).count == OathImportChain.allCases.count, "Soft deletion preserves recoverable account metadata")
        await rejects("Deleted wallet cannot become active") { try await session.selectWallet(UUID(uuidString: third)!) }
        await rejects("Deleted wallet cannot expose recovery material") { _ = try await vault.recoveryWords(walletID: third, digits: pin) }
        let removedAt = try await db.wallet(third)!.deletedAt!
        let nearDeadline = Date(timeIntervalSince1970: removedAt + OathVaultContents.retention - 1)
        _ = try await vault.maintainDeletedWallets(now: nearDeadline)
        check(try await vault.wallets(includingDeleted: true).contains { $0.id == third }, "Retention cannot expire before seven full days")
        try await session.recoverDeletedWallets([third])
        check(session.wallets.count == 3 && session.recentlyDeletedWallets.isEmpty, "Restore returns an intact wallet")
        check(try await db.wallet(second)?.colorHex == "DF438D", "Restore preserves other wallets' appearance")

        // Removing the original member must preserve the credential anchor.
        let rootSoft = OathWalletRemovalAction(ids: [root], permanently: false)
        let rootGrant = try await vault.authorizeWalletRemoval(rootSoft, digits: pin, reason: "")
        try await session.removeWallets(rootSoft, authorization: rootGrant)
        let rootHard = OathWalletRemovalAction(ids: [root], permanently: true)
        let rootPurge = try await vault.authorizeWalletRemoval(rootHard, digits: pin, reason: "")
        try await session.removeWallets(rootHard, authorization: rootPurge)
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        check(sealed.version == 9 && sealed.id.uuidString == root && !sealed.memberIDs.contains(UUID(uuidString: root)!), "Stable credential anchor outlives the first wallet")
        check(try await db.wallet(root) == nil, "Permanent removal deletes public wallet records")
        check(try !sealed.openContents(using: sealed.key(for: pin)).wallets.contains { $0.id.uuidString == root }, "Permanent removal erases recovery material from encrypted payload")
        await session.lock()
        await session.unlockWithBiometrics()
        check(session.isUnlocked && session.wallets.count == 2, "Existing Face ID still unlocks after root wallet deletion")
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.wallets.count == 2, "Existing PIN still unlocks after root wallet deletion")

        // Simulate SQL failure AFTER the encrypted erase commits. Only a durable
        // journal replay may finish it; an old in-memory payload must not return.
        let secondSoft = OathWalletRemovalAction(ids: [second], permanently: false)
        let secondSoftGrant = try await vault.authorizeWalletRemoval(secondSoft, digits: pin, reason: "")
        try await session.removeWallets(secondSoft, authorization: secondSoftGrant)
        let secondHard = OathWalletRemovalAction(ids: [second], permanently: true)
        let secondHardGrant = try await vault.authorizeWalletRemoval(secondHard, digits: pin, reason: "")
        func sql(_ text: String) {
            var connection: OpaquePointer?
            precondition(sqlite3_open(url.path, &connection) == SQLITE_OK)
            defer { sqlite3_close(connection) }
            precondition(sqlite3_exec(connection, text, nil, nil, nil) == SQLITE_OK)
        }
        sql("CREATE TRIGGER fixture_reject_delete BEFORE DELETE ON wallets BEGIN SELECT RAISE(ABORT, 'fixture'); END;")
        await rejects("SQL failure after key erase must be surfaced") { _ = try await vault.removeWallets(secondHard, authorization: secondHardGrant) }
        let interrupted = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let journal = try interrupted.openContents(using: interrupted.key(for: pin))
        check(journal.purgedWalletIDs == [UUID(uuidString: second)!] && !journal.wallets.contains { $0.id.uuidString == second }, "Interrupted purge stores intent without erased keys")
        sql("DROP TRIGGER fixture_reject_delete;")
        await session.lock(); await session.unlock(pin)
        check(session.isUnlocked && session.wallets.map(\.id) == [third], "Unlock replays interrupted purge without resurrecting wallets")
        check(try await db.wallet(second) == nil, "Journal replay finishes SQL cleanup")

        let lastSoft = OathWalletRemovalAction(ids: [third], permanently: false)
        await rejects("Last active wallet cannot silently take the seven-day deletion path") {
            _ = try await vault.authorizeWalletRemoval(lastSoft, digits: pin, reason: "")
        }
        let lastReset = OathWalletRemovalAction(ids: [third], permanently: false, resetsApp: true)
        let lastGrant = try await vault.authorizeWalletRemoval(lastReset, digits: pin, reason: "")
        await rejects("A final reset grant cannot be used as a soft-delete grant") {
            _ = try await vault.removeWallets(lastSoft, authorization: lastGrant)
        }
        try await session.removeWallets(lastReset, authorization: lastGrant)
        check(session.presentsOnboarding && !session.isUnlocked && session.wallets.isEmpty && session.recentlyDeletedWallets.isEmpty,
              "Deleting the last active wallet completes reset and returns to Welcome")
        check(try await !vault.exists(), "Final removal erases the encrypted vault")
        check(try await db.wallets(includingDeleted: true).isEmpty, "Final removal erases active and deleted metadata")
        await rejects("Completed final deletion grant cannot be reused") {
            try await vault.beginReset(removing: lastReset, authorization: lastGrant)
        }
        let coldVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: resetEnvironment)
        let coldSession = OathWalletSession(vault: coldVault)
        await coldSession.load()
        check(coldSession.presentsOnboarding, "Welcome persists after restarting following last-wallet removal")
        checks += try await checkLastWalletReset()
        checks += try await checkWalletReimport()
        print("Passed \(checks) wallet lifecycle checks (synthetic host storage, deletion, restore, ordering, authentication and interrupted writes).")
        return checks
    }
}

extension CheckMultiWallet {
    @MainActor static func checkWalletReimport() async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathReimport-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory()
        let vault = OathWalletVault(storage: storage, database: db)
        let pin: [UInt8] = [1, 4, 7, 2, 5, 8]
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        let generated = try await session.addWallet(requestID: UUID())
        let phrase = OathValidatedMnemonic(phrase: try await vault.recoveryWords().joined(separator: " "), language: "english")
        let originalAccounts = try await db.accounts(walletID: generated)
        func remove(_ id: String, permanently: Bool = false) async throws {
            let action = OathWalletRemovalAction(ids: [id], permanently: permanently)
            let grant = try await vault.authorizeWalletRemoval(action, digits: pin, reason: "Synthetic reimport test")
            try await session.removeWallets(action, authorization: grant)
        }
        try await remove(generated)
        check(!session.wallets.contains { $0.id == generated } && session.recentlyDeletedWallets.contains { $0.id == generated },
              "Removed wallet must start only in Recently Deleted")
        storage.rejectNextUpdate()
        do {
            _ = try await session.addWallet(requestID: UUID(), importing: phrase)
            preconditionFailure("Failed encrypted restore write must fail import")
        } catch { checks += 1 }
        check(try await db.wallet(generated)?.deletedAt != nil, "Failed vault write must not restore SQL membership")
        let reimported = try await session.addWallet(requestID: UUID(), importing: phrase)
        check(reimported == generated, "Reimport must reuse retained wallet identity")
        check(session.wallets.count == 2 && session.recentlyDeletedWallets.isEmpty,
              "Reimport moves wallet out of Recently Deleted into active list")
        check(session.displayedProfile?.id.uuidString == generated, "Reimport must activate the restored wallet")
        check(try await db.accounts(walletID: generated).map(\.address) == originalAccounts.map(\.address),
              "Reimport preserves account addresses")
        let otherID = session.wallets.first { $0.id != generated }!.id
        try await session.selectWallet(UUID(uuidString: otherID)!)
        let duplicate = try await session.addWallet(requestID: UUID(), importing: phrase)
        check(duplicate == generated && session.wallets.count == 2 && session.displayedProfile?.id.uuidString == generated,
              "Existing-wallet import must only activate it")
        await session.lock(); await session.unlock(pin)
        check(session.wallets.count == 2 && session.recentlyDeletedWallets.isEmpty && session.displayedProfile?.id.uuidString == generated,
              "Restored membership and selection must survive unlock")

        // A committed vault restoration with stale SQL is repaired on retry.
        try await remove(generated)
        let sealed = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let key = try sealed.key(for: pin)
        var contents = try sealed.openContents(using: key)
        let index = contents.wallets.firstIndex { $0.id.uuidString == generated }!
        contents.wallets[index].deletedAt = nil
        let repaired = try OathVaultEnvelope.seal(contents, rootID: sealed.id, key: key,
            salt: sealed.salt, iterations: sealed.iterations, protection: sealed.protection, biometricAccess: sealed.biometricAccess)
        try storage.update(JSONEncoder().encode(repaired), account: "vault-v1")
        let restarted = OathWalletVault(storage: storage, database: db)
        _ = try await restarted.unlock(digits: pin)
        let retry = try await restarted.addWallet(requestID: UUID(), importing: phrase)
        let retriedRecord = try await db.wallet(generated)
        check(retry.id.uuidString == generated && retriedRecord?.deletedAt == nil,
              "Interrupted lifecycle reconciliation must recover without duplicates")
        await session.lock(); await session.unlock(pin)

        let material = OathImportedPrivateKey(bytes: Data(repeating: 7, count: 32), networks: [.ethereum, .base])
        let importedKey = try await session.addWallet(requestID: UUID(), privateKey: material)
        try await remove(importedKey)
        let restoredKey = try await session.addWallet(requestID: UUID(), privateKey: material)
        check(restoredKey == importedKey && session.recentlyDeletedWallets.isEmpty,
              "Private-key reimport must also remove the retained entry")
        try await remove(importedKey)
        let backup = BackupWallet(id: UUID(uuidString: importedKey)!, name: "Synthetic restored key", mnemonic: "", language: "",
            createdAt: .now, accounts: material.networks.map { .init(network: $0.id, derivationPath: "imported", index: 0) },
            privateKey: .init(bytes: material.bytes, networks: material.networks.map(\.id)))
        try await session.restoreWallet(OathRestoredWallet(backup: backup))
        check(session.recentlyDeletedWallets.isEmpty && session.displayedProfile?.id.uuidString == importedKey,
              "Backup restore must revive a matching deleted wallet")
        try await remove(importedKey)
        try await remove(importedKey, permanently: true)
        let newKey = try await session.addWallet(requestID: UUID(), privateKey: material)
        check(newKey != importedKey && session.recentlyDeletedWallets.isEmpty && session.wallets.count == 3,
              "Permanently removed material must import as a new wallet")
        return checks
    }
}
