import Foundation
import OathDatabase
import OathDiagnostics

private actor StartupReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private final class ProtectedStorage: OathVaultStorage, @unchecked Sendable {
    let memory = WalletMemory()
    private let mutex = NSLock()
    private var accessible = true
    private var reads = 0, writes = 0, erases = 0
    private var nextError: (any Error)?
    private var lockOnRead = false
    var available: Bool { mutex.withLock { accessible } }
    var counts: (reads: Int, writes: Int, erases: Int) { mutex.withLock { (reads, writes, erases) } }
    func setAvailable(_ value: Bool) { mutex.withLock { accessible = value } }
    func failRead(_ error: any Error, locking: Bool = false) {
        mutex.withLock { nextError = error; lockOnRead = locking }
    }
    func clearCounts() { mutex.withLock { reads = 0; writes = 0; erases = 0 } }
    func read(_ account: String) throws -> Data? {
        try mutex.withLock {
            reads += 1
            if lockOnRead { accessible = false; lockOnRead = false }
            if let error = nextError { nextError = nil; throw error }
            if !accessible { throw CocoaError(.fileWriteNoPermission) }
            return try memory.read(account)
        }
    }
    func insert(_ data: Data, account: String) throws {
        try mutex.withLock { writes += 1; try memory.insert(data, account: account) }
    }
    func update(_ data: Data, account: String) throws {
        try mutex.withLock { writes += 1; try memory.update(data, account: account) }
    }
    func erase() throws { try mutex.withLock { erases += 1; try memory.erase() } }
}

@main struct CheckProtectedWalletStartup {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ reason: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + reason) }
        }
        func loading(_ session: OathWalletSession) -> Bool { if case .loading = session.state { true } else { false } }
        func unavailable(_ session: OathWalletSession) -> Bool { if case .unavailable = session.state { true } else { false } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathProtectedStartup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = StartupReports()
        OathDiagnostics.configure(file: folder.appendingPathComponent("outbox.json"), transport: reports)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = ProtectedStorage()
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [1, 6, 9, 2, 8, 4]
        try await vault.create(digits: pin, importing: .init(phrase: "synthetic protected startup", language: "english"))
        await vault.lock()
        let original = try storage.memory.read("vault-v1")!
        let missingLegacy = folder.appendingPathComponent("absent-legacy.sqlite")
        func session(_ storage: ProtectedStorage, vault: OathWalletVault) -> OathWalletSession {
            OathWalletSession(vault: vault, legacySourceURL: missingLegacy,
                              protectedDataAvailable: { storage.available })
        }
        storage.clearCounts()
        storage.setAvailable(false)
        let blocked = session(storage, vault: vault)
        await blocked.load()
        check(loading(blocked) && !blocked.isUnlocked && !blocked.presentsOnboarding, "Protected startup waits without opening a wallet or onboarding")
        check(storage.counts.reads == 0 && storage.counts.writes == 0 && storage.counts.erases == 0, "Protected startup performs no vault reads, writes or reset")
        await blocked.resumeProtectedStartup()
        check(storage.counts.reads == 0, "Repeated notification while still protected does no I/O")
        storage.setAvailable(true)
        await blocked.resumeProtectedStartup()
        check(blocked.isLocked && !blocked.isUnlocked, "Data availability resumes startup to the app PIN, not unlocked Home")
        let reads = storage.counts.reads
        await blocked.resumeProtectedStartup()
        check(storage.counts.reads == reads, "Duplicate availability notifications do not reload an initialized wallet")
        check(try storage.memory.read("vault-v1") == original && storage.counts.erases == 0, "Resuming preserves the encrypted wallet")

        // Protection can change after the initial availability check, during I/O.
        for error: any Error in [CocoaError(.fileWriteNoPermission), CocoaError(.fileReadNoPermission), OathPasscodeSaveError.deviceLocked,
                                OathInstallationSecurityError.keychain(-25308)] {
            storage.setAvailable(true)
            storage.failRead(error, locking: true)
            let racing = session(storage, vault: vault)
            await racing.load()
            check(loading(racing) && !racing.presentsOnboarding, "Protection race remains retryable")
            storage.setAvailable(true)
            await racing.resumeProtectedStartup()
            check(racing.isLocked, "Protection race resumes to PIN after the OS unlocks its data")
        }
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        check(await reports.events.isEmpty, "Expected protected-data deferral does not report an app failure")

        // An unlocked permission failure and missing entitlements are genuine
        // failures, even if protection changes concurrently. Never swallow them.
        for (error, locks): (any Error, Bool) in [(CocoaError(.fileWriteNoPermission), false),
                (OathInstallationSecurityError.keychain(-34018), false),
                (OathInstallationSecurityError.keychain(-34018), true)] {
            storage.setAvailable(true)
            storage.failRead(error, locking: locks)
            let failed = session(storage, vault: vault)
            await failed.load()
            check(unavailable(failed) && !failed.isUnlocked, "Genuine permission/entitlement failure remains unavailable")
            storage.setAvailable(true)
            await failed.resumeProtectedStartup()
            check(unavailable(failed), "An availability event cannot silently retry a genuine failure")
        }
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let events = await reports.events
        check(events.count == 3, "Exactly the three genuine failures reach the shared outbox")
        check(events.allSatisfy { $0.operationID != nil && $0.context["stage"] == "vault_read" && $0.privacyFiltered },
              "Genuine startup failures carry a safe stage and correlation ID")
        check(Set(events.compactMap(\.operationID)).count == 3, "Startup attempts have independent correlation IDs")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        check(!encoded.contains(folder.path) && !encoded.contains("synthetic protected startup"), "Startup diagnostics contain no file path or wallet material")

        let emptyStorage = ProtectedStorage()
        emptyStorage.setAvailable(false)
        let empty = session(emptyStorage, vault: OathWalletVault(storage: emptyStorage, biometricStore: MemoryBiometrics(), database: db))
        await empty.load()
        check(loading(empty) && !empty.presentsOnboarding, "Unknown protected installation is never inferred to be empty")
        emptyStorage.setAvailable(true)
        await empty.resumeProtectedStartup()
        check(empty.presentsOnboarding && !empty.isUnlocked, "A verified empty installation can open onboarding after availability")
        print("Protected wallet startup: \(checks - failures)/\(checks) host checks passed; \(failures) failed. No simulator, device, user Keychain or network used.")
        if failures > 0 { exit(1) }
    }
}
