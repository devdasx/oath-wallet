import Foundation
import CryptoKit
import OathDatabase
import OathDiagnostics

private actor CompatibilityReports: DiagnosticTransport {
    private(set) var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

/// A newer app can add public accounts before an older app opens the same
/// installation. Exercise the production database, vault and session without
/// accessing a real Keychain, wallet, provider, simulator or device.
@main struct CheckStoredNetworkCompatibility {
    @MainActor static func main() async throws {
        var checks = 0, failures = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + message) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathNetworkCompatibility-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = CompatibilityReports()
        OathDiagnostics.configure(file: folder.appendingPathComponent("outbox.json"), transport: reports)
        let pin: [UInt8] = [1, 6, 9, 2, 8, 4]
        let future = "future-chain-fixture"
        check(OathImportChain(rawValue: future) == nil, "Fixture represents a network absent from this binary")

        for pinEnabled in [false, true] {
            let databaseURL = folder.appendingPathComponent(pinEnabled ? "pin/wallet.sqlite" : "automatic/wallet.sqlite")
            let database = try await OathDatabase.open(at: databaseURL)
            try await OathDataEnvironment.seed(database)
            let storage = WalletMemory(), biometrics = MemoryBiometrics()
            let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: database)
            try await vault.create(digits: pin, importing: .init(phrase: "synthetic compatibility fixture", language: "english"))
            let originalProfile = try await vault.unlockedProfile()
            if !pinEnabled {
                let authorization = try await vault.authorizeSecurityChange(digits: pin)
                try await vault.setPasscode(nil, authorization: authorization)
            }
            let originalVault = try storage.read("vault-v1")!
            let walletID = originalProfile.id.uuidString
            let wallet = try await database.wallet(walletID)!
            let account = AccountRecord(id: "future-account-fixture", walletID: walletID, networkID: future,
                                        address: "synthetic-public-address", derivationPath: "synthetic-path")
            try await database.seed(networks: [NetworkRecord(id: future, name: "Future Chain", family: "evm", symbol: "FUT",
                decimals: 18, derivationPath: "synthetic-path", logo: "fixture", sortOrder: 999)],
                assets: [AssetRecord(id: future + ":native", networkID: future, reference: "native", name: "Future Coin", symbol: "FUT", decimals: 18)])
            try await database.importWalletIfNeeded(wallet, accounts: [account])
            let before = try await database.accounts(walletID: walletID)
            let snapshot = try await database.snapshot(walletID: walletID, currency: "USD")
            if let supported = before.first(where: { OathImportChain(rawValue: $0.networkID) != nil }),
               let chain = OathImportChain(rawValue: supported.networkID) {
                let fallback = OathWalletAddress.stored(supported, network: nil)
                check(fallback?.address == supported.address && fallback?.accountID == supported.id &&
                      fallback?.path == supported.derivationPath && fallback?.storedTicker == chain.ticker,
                      "Missing display metadata preserves the persisted address and uses bundled labels")
            } else { check(false, "Missing supported fixture account") }
            do {
                let projected = try OathWalletProfile.stored(snapshot)
                check(projected.addresses == originalProfile.addresses,
                      "A future network preserves every supported address and account identity")
            } catch {
                check(false, "A future public account must not be classified as corruptVault")
            }
            await vault.lock()
            let reopenedDatabase = try await OathDatabase.open(at: databaseURL)
            let reopenedVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: reopenedDatabase)
            let session = OathWalletSession(vault: reopenedVault, legacySourceURL: folder.appendingPathComponent("absent-legacy.sqlite"))
            await session.load()
            if pinEnabled {
                check(session.isLocked, "A future network never bypasses the app PIN")
                await session.unlock(pin)
            }
            check(session.isUnlocked && session.displayedProfile?.id == originalProfile.id,
                  pinEnabled ? "PIN unlock opens the existing wallet with a future account" : "Automatic startup opens the existing wallet with a future account")
            check(try await reopenedDatabase.accounts(walletID: walletID) == before,
                  "Opening an older network catalogue preserves all public accounts")
            check(try storage.read("vault-v1") == originalVault, "Compatibility projection does not rewrite encrypted wallet material")
            check(try await reopenedDatabase.pendingWalletReset() == nil && !session.presentsOnboarding,
                  "A future network never causes reset or fresh onboarding")
            check(session.portfolio?.accounts.contains(account) == true,
                  "The full persisted snapshot retains the future account")
            await reopenedVault.lock()
            if !pinEnabled {
                let original = try JSONDecoder().decode(OathVaultEnvelope.self, from: originalVault)
                let key = try original.deviceKey()
                let baseline = try original.openContents(using: key)
                let ids = baseline.wallets.map(\.id)
                let aad = Data(("org.oathwallet.vault.v10:" + original.id.uuidString + ":" +
                                ids.map(\.uuidString).joined(separator: ":")).utf8)
                for valid in [false, true] {
                    var old = baseline
                    old.lifecycleVersion = nil
                    if valid { old.legacyBiometricTransition = false }
                    let box = try AES.GCM.seal(JSONEncoder().encode(old), using: key, authenticating: aad)
                    let historical = OathVaultEnvelope(version: 10, id: original.id, salt: original.salt,
                        iterations: original.iterations, sealed: box.combined!, walletIDs: ids,
                        protection: original.protection, biometricAccess: false)
                    let bytes = try JSONEncoder().encode(historical)
                    try storage.update(bytes, account: "vault-v1")
                    let cold = OathWalletSession(vault: reopenedVault, legacySourceURL: folder.appendingPathComponent("absent-legacy.sqlite"))
                    await cold.load()
                    if valid {
                        check(cold.isUnlocked && cold.displayedProfile?.id == originalProfile.id,
                              "Cold launch opens an authenticated legacy v10 vault with a missing lifecycle marker")
                    } else {
                        if case .unavailable = cold.state { check(true, "Unexpected lifecycle mismatch remains closed") }
                        else { check(false, "Unexpected lifecycle mismatch remains closed") }
                        check(try storage.read("vault-v1") == bytes, "A rejected wallet retains its original ciphertext")
                    }
                    await reopenedVault.lock()
                }
            }
        }
        // Display compatibility must not weaken wallet identity validation.
        let invalidDatabase = try await OathDatabase.open(at: folder.appendingPathComponent("invalid/wallet.sqlite"))
        try await OathDataEnvironment.seed(invalidDatabase)
        try await invalidDatabase.importWalletIfNeeded(
            WalletRecord(id: "invalid-wallet-identity", name: "Fixture", kind: "watchOnly", vaultReference: "fixture", createdAt: 1),
            accounts: [AccountRecord(id: "invalid-wallet-account", walletID: "invalid-wallet-identity", networkID: "ethereum",
                                     address: "synthetic-public-address", derivationPath: "synthetic-path")])
        do {
            _ = try OathWalletProfile.stored(await invalidDatabase.snapshot(walletID: "invalid-wallet-identity", currency: "USD"))
            check(false, "Malformed wallet identity remains a real failure")
        } catch OathWalletError.corruptVault {
            check(true, "Malformed wallet identity remains a real failure")
        }
        try await Task.sleep(for: .milliseconds(200))
        await OathDiagnostics.flush()
        let startupFailures = await reports.events.filter {
            $0.sourceFile.hasSuffix("OathWalletSession.swift") || $0.sourceFile.hasSuffix("OathDataEnvironment.swift")
        }
        check(startupFailures.contains { $0.context["reason"] == "network_metadata_fallback" }, "Label fallback reaches the background outbox")
        check(startupFailures.contains { $0.context["reason"] == "invalid_stored_wallet_identity" }, "Identity rejection reports its safe guard reason")
        let loadFailures = startupFailures.filter { $0.operation == "load" }
        let guardReports = await reports.events.filter { $0.context["reason"] == "payload_lifecycle_mismatch" }
        check(loadFailures.count == 1 && loadFailures.first?.context["stage"] == "vault_open" &&
              loadFailures.first?.operationID != nil && guardReports.contains { $0.operationID == loadFailures.first?.operationID },
              "Startup reports the exact failing guard and vault stage under the same operation ID")
        check(startupFailures.filter { $0.error.message == "corruptVault" }.allSatisfy {
            $0.operation == "load" || $0.context["reason"] == "invalid_stored_wallet_identity"
        },
              "Expected future network metadata does not emit a corruption report")
        if failures > 0 {
            for event in await reports.events {
                print("Fixture report", event.operation, event.context["stage"] ?? "-", event.context["reason"] ?? "-")
            }
        }
        print("Stored network compatibility: \(checks - failures)/\(checks) host checks passed; \(failures) failed. No simulator, device, real Keychain or network used.")
        if failures > 0 { exit(1) }
    }
}
