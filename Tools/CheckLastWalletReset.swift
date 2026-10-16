import Foundation
import OathDatabase
import SQLite3

actor LifecycleResetEnvironment: OathResetEnvironment {
    private var fails = false
    private(set) var erasures = 0
    func failNextErase() { fails = true }
    func suspend() { }
    func eraseLocalFiles() throws {
        erasures += 1
        if fails { fails = false; throw CocoaError(.fileWriteNoPermission) }
    }
    func reopen() { }
}

extension CheckMultiWallet {
    @MainActor static func checkLastWalletReset() async throws -> Int {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<600 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
            preconditionFailure("Last-wallet fixture timed out")
        }
        let pin: [UInt8] = [1, 2, 8, 4, 7, 3]
        // No security, PIN fallback, enrolled biometrics; empty/populated trash;
        // pending send; interrupted key/file erasure; failed journal commit.
        for (mode, trashCount, fault) in [(0, 0, ""), (0, 2, "journal"), (1, 2, "key"), (2, 0, "files")] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("last-wallet-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.sqlite")
            let db = try await OathDatabase.open(at: url)
            try await OathDataEnvironment.seed(db)
            let storage = WalletMemory(), biometrics = MemoryBiometrics(), environment = LifecycleResetEnvironment()
            let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: environment)
            try await vault.create(digits: pin, importing: nil)
            let session = OathWalletSession(vault: vault)
            await session.finishedSetup(); session.finishInitialCustomization()
            if mode == 0 {
                let grant = try await vault.authorizeSecurityChange(digits: pin)
                try await vault.setPasscode(nil, authorization: grant)
            } else if mode == 2 {
                await biometrics.enroll(try await vault.biometricCredential())
            }
            try await session.refreshSecurity()
            let last = session.wallets[0].id
            for _ in 0..<trashCount {
                let id = try await session.addWallet(requestID: UUID())
                let action = OathWalletRemovalAction(ids: [id], permanently: false)
                let grant = try await vault.authorizeWalletRemoval(action, digits: mode == 0 ? nil : pin, reason: "fixture")
                try await session.removeWallets(action, authorization: grant)
            }
            check(session.wallets.map(\.id) == [last] && session.recentlyDeletedWallets.count == trashCount,
                  "Fixture contains one active wallet and the expected trash")
            let account = try await db.accounts(walletID: last).first { $0.networkID == "ethereum" }!
            try await db.saveDraft(.init(id: "fixture-send", walletID: last, accountID: account.id,
                networkID: "ethereum", assetID: "ethereum:native", idempotencyKey: "fixture-send",
                recipient: "synthetic-recipient", amountAtomic: "1", state: "draft", createdAt: 1, updatedAt: 1))
            _ = try await db.queueSend("fixture-send", networkNonce: 0)
            do {
                try await db.validateWalletRemoval([last])
                preconditionFailure("Pending sends block ordinary removal regardless of security settings")
            } catch { checks += 1 }

            let model = OathWalletRemovalModel(session: session)
            let requested = OathWalletRemovalAction(ids: [last], permanently: false)
            let readCount = await biometrics.reads
            func authorize() async throws {
                model.begin(requested, reason: "Synthetic final removal")
                if mode == 1 {
                    try await wait { model.phase == .passcode }
                    model.submit(pin)
                }
                try await wait { model.phase == .confirmation || model.phase == .recentlyDeletedConfirmation }
            }
            try await authorize()
            check(model.action?.resetsApp == true, "Shared deletion model detects final-wallet reset")
            check(model.action?.recentlyDeletedIDs == Set(session.recentlyDeletedWallets.map(\.id)),
                  "Reset grant binds exact Recently Deleted membership")
            if mode == 0 { check(await biometrics.reads == readCount, "Security disabled never prompts for credentials") }
            if mode == 2 { check(await biometrics.reads == readCount + 1, "Enabled biometrics freshly authenticate") }
            let before = try storage.read("vault-v1")
            if trashCount > 0 {
                check(model.phase == .recentlyDeletedConfirmation, "Trash must be confirmed first")
                model.confirm()
                check(!model.confirming, "Final deletion cannot skip the trash confirmation")
                model.confirmRecentlyDeleted()
                try await wait { model.phase == .confirmation }
            }
            check(try storage.read("vault-v1") == before, "Neither confirmation staging nor authentication erases keys")
            model.cancel()
            check(try await db.pendingWalletReset() == nil, "Cancellation before final confirmation records no destructive intent")
            check(try await db.wallets(includingDeleted: true).count == trashCount + 1, "Cancel preserves active and deleted wallets")

            if fault != "" {
                // A newly added wallet invalidates a grant; it cannot silently grow
                // from the reviewed membership into permission to erase new data.
                let boundAction = OathWalletRemovalAction(ids: [last], permanently: false, resetsApp: true,
                    recentlyDeletedIDs: Set(session.recentlyDeletedWallets.map(\.id)))
                let bound = try await vault.authorizeWalletRemoval(boundAction, digits: mode == 0 ? nil : pin, reason: "fixture")
                let added = try await session.addWallet(requestID: UUID())
                do {
                    try await vault.beginReset(removing: boundAction, authorization: bound)
                    preconditionFailure("Stale membership must not reset newly added wallets")
                } catch { checks += 1 }
                check(try await db.pendingWalletReset() == nil, "Stale grant commits no reset journal")
                let removeAdded = OathWalletRemovalAction(ids: [added], permanently: false)
                let removeGrant = try await vault.authorizeWalletRemoval(removeAdded, digits: mode == 0 ? nil : pin, reason: "fixture")
                try await session.removeWallets(removeAdded, authorization: removeGrant)

            }

            func sql(_ sql: String) {
                var connection: OpaquePointer?
                precondition(sqlite3_open(url.path, &connection) == SQLITE_OK)
                defer { sqlite3_close(connection) }
                sqlite3_busy_timeout(connection, 5000)
                precondition(sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK)
            }
            var callbacks = 0
            func confirm() async throws {
                try await authorize()
                if model.phase == .recentlyDeletedConfirmation {
                    model.confirmRecentlyDeleted()
                    try await wait { model.phase == .confirmation }
                }
                model.confirm { _ in callbacks += 1 }
                model.confirm { _ in callbacks += 1 }
                try await wait { model.phase == .idle && !model.confirming }
            }
            if fault == "journal" {
                sql("CREATE TRIGGER fixture_block_reset BEFORE INSERT ON metadata WHEN NEW.key='walletReset' BEGIN SELECT RAISE(ABORT,'fixture'); END;")
                try await confirm()
                check(model.notice == .walletRemovalFailed && callbacks == 0, "Journal failure cannot report deletion success")
                check(session.isUnlocked && !session.resetting, "Failed journal write recovers without asking for a disabled PIN")
                check(try await db.wallets(includingDeleted: true).count == trashCount + 2, "Journal failure preserves all wallets")
                sql("DROP TRIGGER fixture_block_reset;")
            } else if fault == "key" { storage.rejectNextErase() }
            else if fault == "files" { await environment.failNextErase() }
            try await confirm()
            if fault == "key" || fault == "files" {
                check(session.resetting && session.resetFailed && !session.presentsOnboarding && callbacks == 0,
                      "Interrupted cleanup never reports success or opens Welcome early")
                check(try await db.pendingWalletReset() != nil, "Interrupted reset retains durable intent")
                if fault == "files" {
                    await session.retryReset()
                    check(session.presentsOnboarding && !session.resetFailed, "Retry finishes cleanup")
                } else {
                    let nextVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: environment)
                    let next = OathWalletSession(vault: nextVault)
                    await next.load()
                    try await wait { next.presentsOnboarding || next.resetFailed }
                    check(next.presentsOnboarding && !next.resetFailed, "Cold launch resumes confirmed deletion without credentials")
                }
            } else {
                check(session.presentsOnboarding && callbacks == 1, "Successful final deletion navigates once to Welcome")
            }
            check(try storage.read("vault-v1") == nil, "All active/deleted key material is removed")
            check(try await db.wallets(includingDeleted: true).isEmpty, "All wallet metadata is removed")
            check(try await db.send("fixture-send") == nil, "Pending local send journal is removed by explicit reset")
            check(try await db.pendingWalletReset() == nil, "Only complete cleanup clears the reset journal")
            check(try await !biometrics.hasEnrollment(), "Reset removes biometric enrollment")
            let freshVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db, resetEnvironment: environment)
            let fresh = OathWalletSession(vault: freshVault)
            await fresh.load()
            check(fresh.presentsOnboarding, "Relaunch stays at Welcome")
            try await freshVault.create(digits: pin, importing: nil)
            await fresh.finishedSetup(); fresh.finishInitialCustomization()
            check(fresh.isUnlocked && fresh.wallets.count == 1 && fresh.wallets[0].id != last,
                  "Creating a new wallet after final deletion works without resurrecting old data")
            await fresh.lock(); await session.lock()
        }
        return checks
    }
}
