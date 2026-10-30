import Foundation
import OathDatabase
import OathDiagnostics
import OathBitcoin

private actor SessionReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private final class SessionStorage: OathVaultStorage, @unchecked Sendable {
    let memory = WalletMemory()
    private let lock = NSLock()
    private var failure: NSError?
    func failNextRead(_ error: NSError) { lock.withLock { failure = error } }
    func read(_ account: String) throws -> Data? {
        try lock.withLock {
            if let error = failure { failure = nil; throw error }
            return try memory.read(account)
        }
    }
    func insert(_ data: Data, account: String) throws { try memory.insert(data, account: account) }
    func update(_ data: Data, account: String) throws { try memory.update(data, account: account) }
    func erase() throws { try memory.erase() }
}

/// Production session, encrypted vault, persistent attempt counters and outbox.
/// Only derivation, sync, storage and OS prompts use the existing host fixtures.
@main struct CheckWalletSessionDiagnostics {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ reason: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + reason) }
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathSession-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = SessionReports()
        OathDiagnostics.configure(file: directory.appendingPathComponent("outbox.json"), transport: reports)
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = SessionStorage()
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [1, 6, 9, 2, 8, 4]
        try await vault.create(digits: pin, importing: .init(phrase: "synthetic session fixture", language: "english"))
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        session.finishInitialCustomization()
        let id = session.displayedProfile!.id
        await session.lock(reason: .automatic)
        for _ in 0..<5 {
            await session.unlock([9, 9, 9, 9, 9, 9])
            check(session.isLocked && !session.isUnlocked && session.notice == .unlockIncorrect && !session.busy,
                  "Wrong PIN stays locked, shows the existing message and releases busy state")
        }
        let attempts = try JSONDecoder().decode(OathUnlockAttempts.self, from: storage.read("unlock-attempts-v1")!)
        check(attempts.failures == 5 && attempts.blockedUntil != nil, "Five failures persist the existing lockout")
        await session.unlock(pin)
        check(session.isLocked && session.notice == .unlockWait, "Even the correct PIN cannot bypass lockout")
        let reopened = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        do { _ = try await reopened.unlock(digits: pin); check(false, "Lockout survives reopening") }
        catch OathWalletError.throttled { check(true, "Lockout survives reopening") }
        // Explicit test clock advances only the vault call; no production timer or PIN bypass.
        _ = try await reopened.unlock(digits: pin, now: attempts.blockedUntil!.addingTimeInterval(1))
        await reopened.lock()
        await session.unlock(pin)
        check(session.isUnlocked && session.displayedProfile?.id == id && session.notice == nil,
              "Correct PIN after expiry opens the same wallet")
        let cleared = try JSONDecoder().decode(OathUnlockAttempts.self, from: storage.read("unlock-attempts-v1")!)
        check(cleared.failures == 0 && cleared.blockedUntil == nil, "Successful authentication clears retry counters")
        let grant = try await vault.authorizeSecurityChange(digits: pin)
        try await vault.setPasscode(pin, authorization: grant)
        check(try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!).protection?.wrappedKey != nil,
              "Changed PIN fixture uses a separately authenticated wrapped data key")
        await session.lock(reason: .automatic)
        await session.unlock([9, 9, 9, 9, 9, 9])
        check(session.isLocked && session.notice == .unlockIncorrect, "Wrapped key still rejects the wrong PIN")
        await session.unlock(pin)
        check(session.isUnlocked, "Wrapped key accepts only the correct PIN")
        await session.lock(reason: .automatic)
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let ordinary = await reports.events
        check(ordinary.filter { $0.sourceFile.hasSuffix("OathWalletSession.swift") }.isEmpty,
              "Session does not duplicate expected PIN rejection or lockout")
        check(ordinary.contains { $0.sourceFile.hasSuffix("OathVaultEnvelope.swift") },
              "Underlying authenticated-ciphertext failures remain visible: PIN mismatch and damaged key wrapping are indistinguishable")

        // Real failures with the same visible fallback remain reported.
        for code in [513, 257] {
            storage.failNextRead(NSError(domain: NSCocoaErrorDomain, code: code))
            await session.unlock(pin)
            check(session.isLocked && session.notice == .walletUnavailable && !session.busy,
                  "Storage failure cannot unlock or masquerade as an incorrect PIN")
        }
        let original = try storage.read("vault-v1")!
        try storage.update(Data("invalid fixture JSON".utf8), account: "vault-v1")
        await session.unlock(pin)
        check(session.isLocked && session.notice == .walletUnavailable, "Damaged envelope stays locked")
        // A valid PIN unwraps the current data key. A damaged payload after
        // that point is corruption, not a wrong PIN and not another PIN attempt.
        var damaged = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var ciphertext = Data(base64Encoded: damaged["sealed"] as! String)!
        ciphertext[ciphertext.count - 1] ^= 1
        damaged["sealed"] = ciphertext.base64EncodedString()
        let damagedData = try JSONSerialization.data(withJSONObject: damaged)
        try storage.update(damagedData, account: "vault-v1")
        await session.unlock(pin)
        check(session.isLocked && session.notice == .walletUnavailable,
              "Correct PIN with damaged payload reports unavailable, never incorrect PIN")
        let damagedAttempts = try JSONDecoder().decode(OathUnlockAttempts.self, from: storage.read("unlock-attempts-v1")!)
        check(try storage.read("vault-v1") == damagedData, "Corruption handling never erases or replaces encrypted wallet data")
        check(damagedAttempts.failures == 0 && damagedAttempts.blockedUntil == nil,
              "Authenticated payload damage must not consume the incorrect-PIN budget")
        try storage.update(original, account: "vault-v1")
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let genuine = await reports.events
        check(genuine.filter { $0.error.domain == NSCocoaErrorDomain && [513, 257].contains($0.error.code) }.count == 2, "Both real storage failures reach telemetry")
        check(genuine.contains { $0.error.type.contains("DecodingError") }, "Corrupt data remains diagnosable")
        let sessionFailures = genuine.filter { $0.sourceFile.hasSuffix("OathWalletSession.swift") }
        check(sessionFailures.count == 4 && sessionFailures.allSatisfy { $0.operationID != nil },
              "Storage, JSON and payload failures have correlated session reports")
        check(Set(sessionFailures.compactMap(\.operationID)).count == 4, "Independent unlock failures have fresh operation IDs")
        check(genuine.allSatisfy { $0.privacyFiltered }, "Every report passes shared privacy filtering")
        let payload = String(decoding: try JSONEncoder().encode(genuine), as: UTF8.self)
        check(!payload.contains(id.uuidString) && !payload.contains("synthetic session fixture"), "No wallet identity or material enters telemetry")
        await session.unlock(pin)
        check(session.isUnlocked && session.displayedProfile?.id == id, "A retried storage read recovers without resetting the wallet")
        // Use the production session aggregation and native refresh boundary.
        // Only the network adapter is replaced: its exact error must survive
        // aggregation so availability filtering cannot be bypassed by a generic
        // wallet-unavailable wrapper. The visible refresh still fails.
        let refreshFailures: [(bitcoin: Bool, availability: Bool, error: any Error)] = [
            (false, true, NSError(domain: "Oath.HTTP", code: 503)),
            (true, true, BitcoinError.timeout),
            (false, false, NSError(domain: NSCocoaErrorDomain, code: 513))]
        for test in refreshFailures {
            try await Task.sleep(for: .milliseconds(200))
            await OathDiagnostics.flush()
            let before = await reports.events.count
            let otherChains = await OathAnkrSync.shared.completedSolanaRefreshes
            await OathAnkrSync.shared.setRefreshFailure(test.bitcoin ? nil : test.error)
            await OathBitcoinSync.shared.setRefreshFailure(test.bitcoin ? test.error : nil)
            let outcome = await RefreshAction.run(action: { try await session.refresh() }, isCurrent: { true })
            check(outcome == .failed, "Refresh failure remains visible to the native refresh control")
            check(session.isUnlocked && session.displayedProfile?.id == id,
                  "A refresh failure preserves the selected unlocked wallet")
            let completed = await OathAnkrSync.shared.completedSolanaRefreshes
            check(completed > otherChains, "One failing provider does not cancel unrelated chain work")
            try await Task.sleep(for: .milliseconds(200))
            await OathDiagnostics.flush()
            let fresh = Array(await reports.events.dropFirst(before))
            check(!fresh.contains { $0.error.domain.hasSuffix("OathWalletError") },
                  "Refresh keeps the original error instead of manufacturing unavailable reports")
            if test.availability {
                check(fresh.isEmpty, "An availability-only failure stays excluded through the native refresh boundary")
            } else {
                check(fresh.contains { $0.component == "OathNativeRefresh" && $0.error.domain == NSCocoaErrorDomain && $0.error.code == 513 },
                      "A genuine storage failure remains reported at the native refresh boundary")
            }
        }
        await OathAnkrSync.shared.setRefreshFailure(nil)
        await OathBitcoinSync.shared.setRefreshFailure(nil)
        let recovered = await RefreshAction.run(action: { try await session.refresh() }, isCurrent: { true })
        check(recovered == .succeeded, "Refresh recovers after the provider recovers")
        await session.lock(reason: .automatic)
        print("Wallet session diagnostics: \(checks - failures)/\(checks) host checks passed; \(failures) failed. No simulator, device, user Keychain or network used.")
        if failures > 0 { exit(1) }
    }
}
