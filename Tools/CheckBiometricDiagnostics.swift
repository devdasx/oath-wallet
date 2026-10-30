import Foundation
import OathDatabase
import OathDiagnostics
import Security

private actor AuthenticationReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

/// Runs production authentication models/vault/outbox with memory-only wallet
/// storage and biometric replies. No OS prompt, user Keychain or network access.
@main struct CheckBiometricDiagnostics {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures += 1; print("FAIL: " + message) }
        }
        func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<1_000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            throw DiagnosticFailure("authentication_fixture_timeout")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OathAuthReports-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reports = AuthenticationReports()
        OathDiagnostics.configure(file: directory.appendingPathComponent("outbox.json"), transport: reports)
        let db = try await OathDatabase.open(at: directory.appendingPathComponent("wallet.sqlite"))
        try await OathDataEnvironment.seed(db)
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [1, 6, 9, 2, 8, 4]
        try await vault.create(digits: pin, importing: .init(phrase: "synthetic fallback fixture", language: "english"))
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup()
        session.finishInitialCustomization()
        let root = session.displayedProfile!.id.uuidString
        let access = OathSecurityAccessModel(session: session)
        let recovery = OathRecoveryPhraseModel(walletID: root, reader: vault)
        let privateKey = OathPrivateKeyModel(walletID: root, reader: vault)
        await privateKey.load()
        let account = privateKey.accounts.first!
        let removal = OathWalletRemovalModel(session: session)
        let reset = OathResetModel(session: session)

        func exercise(_ failure: OathBiometricCredentialError?) async throws {
            if let failure { await biometrics.failNextRead(failure) }
            reset.begin(reason: "Synthetic reset")
            try await wait { !reset.busy }
            check(reset.phase == .passcode && reset.notice == nil, "Reset retains passcode fallback")
            reset.cancel()

            if let failure { await biometrics.failNextRead(failure) }
            access.begin(reason: "Synthetic Security access")
            try await wait { !access.busy }
            check(access.phase == .passcode && !access.isAuthorized && access.notice == nil, "Security remains locked behind the PIN")
            access.cancel()

            if let failure { await biometrics.failNextRead(failure) }
            recovery.acknowledge(reason: "Synthetic recovery access")
            try await wait { !recovery.busy }
            check(recovery.phase == .passcode && recovery.words.isEmpty && recovery.notice == nil, "Recovery material stays hidden")
            recovery.returnToWarning()

            if let failure { await biometrics.failNextRead(failure) }
            privateKey.select(account, reason: "Synthetic key access")
            try await wait { !privateKey.busy }
            check(privateKey.phase == .passcode && privateKey.key == nil && privateKey.notice == nil, "Private key stays hidden")
            privateKey.returnToChains()

            if let failure { await biometrics.failNextRead(failure) }
            removal.begin(.init(ids: [root], permanently: false), reason: "Synthetic removal")
            try await wait { !removal.busy }
            check(removal.phase == .passcode && removal.notice == nil, "Removal still requires authentication")
            removal.cancel()
        }

        // First reproduce the real passcode-only path: disabled biometrics
        // returns missing directly from the vault, with no protected read.
        try await vault.disableBiometrics()
        try await exercise(nil)
        check(await biometrics.reads == 0, "Passcode-only flows never invoke the biometric store")
        await biometrics.allowEnrollment()
        _ = try await vault.enableBiometrics(strings: .current)
        for outcome in [OathBiometricCredentialError.missing, .cancelled, .unavailable, .keychain(errSecAuthFailed)] {
            try await exercise(outcome)
        }
        // Negative controls: damaged data and unexpected OS failures must still
        // reach the real privacy-filtered outbox, even when the PIN is offered.
        for failure in [OathBiometricCredentialError.invalid, .keychain(errSecDecode)] {
            try await exercise(failure)
        }
        // Bitcoin's authentication boundary also falls back to the app PIN.
        // Exercise the real shared send adapter, without signing or broadcasting.
        for outcome in [OathBiometricCredentialError.missing, .cancelled, .unavailable, .keychain(errSecAuthFailed)] {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                await OathSendDiagnostics.shared.record(stage: "authenticate", error: outcome)
            }
        }
        for failure in [OathBiometricCredentialError.invalid, .keychain(errSecDecode)] {
            await OathDiagnostics.$operationID.withValue(UUID()) {
                await OathSendDiagnostics.shared.record(stage: "authenticate", error: failure)
            }
        }
        await OathDiagnostics.$operationID.withValue(UUID()) {
            await OathSendDiagnostics.shared.record(stage: "preflight", error: OathBiometricCredentialError.missing)
        }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.count >= 13 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let events = await reports.events
        let expected = events.filter { $0.operation != "preflight" && ["missing", "cancelled", "unavailable", "keychain(\(errSecAuthFailed))"].contains($0.error.message) }
        check(expected.isEmpty, "Expected biometric/PIN fallback must not create app errors")
        let sendFailures = events.filter { $0.component == "send" && $0.operation == "authenticate" }
        check(sendFailures.count == 2, "Send authentication reports only genuine credential/keychain failures")
        check(sendFailures.allSatisfy { $0.operationID != nil && $0.privacyFiltered }, "Send failures retain correlation and privacy filtering")
        check(events.filter { $0.component == "send" && $0.operation == "preflight" }.count == 1,
              "The authentication exclusion cannot hide failures in other send stages")
        let sources = ["OathResetModel.swift", "OathSecurityModel.swift", "OathRecoveryPhraseModel.swift", "OathPrivateKeyModel.swift", "OathWalletRemovalModel.swift"]
        var ids: Set<UUID> = []
        for source in sources {
            let failures = events.filter { $0.sourceFile.hasSuffix(source) && ($0.error.message == "invalid" || $0.error.message == "keychain(\(errSecDecode))") }
            check(failures.count == 2, source + " reports each unexpected failure exactly once")
            check(failures.allSatisfy { $0.operationID != nil && $0.privacyFiltered }, source + " preserves correlation and privacy filtering")
            ids.formUnion(failures.compactMap(\.operationID))
        }
        check(ids.count == 10, "Independent authentication attempts have independent operation IDs")
        let payload = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for forbidden in [root, account.address, "synthetic fallback fixture", "Synthetic reset", "Synthetic key access"] {
            check(!payload.contains(forbidden), "No wallet identity, material or UI reason enters telemetry")
        }
        check(try await db.pendingWalletReset() == nil && session.wallets.count == 1, "Authentication checks never erase wallet data")
        print("Authentication diagnostics: \(checks - failures)/\(checks) host checks passed; \(failures) failed. No simulator, device, user Keychain or network used.")
        if failures > 0 { exit(1) }
    }
}
