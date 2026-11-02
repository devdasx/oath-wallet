import Foundation
import OathDatabase

/// Run in distinct writer/reader processes over the same disposable fixture.
/// The harness substitutes synthetic derivation, Keychain and biometric storage.
private struct FixtureCredentialCleanup: OathInstallationCredentialClearing {
    let allowFresh: Bool
    func clear() throws {
        guard allowFresh else { throw OathWalletError.unavailable }
    }
}

@main struct CheckCrossBuildPasscode {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["OATH_SYNTHETIC_UPGRADE_DIR"], let mode = env["OATH_SYNTHETIC_UPGRADE_MODE"],
              ["write", "older", "return"].contains(mode) else { preconditionFailure("Supply a disposable test directory and mode") }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let marker = dir.appendingPathComponent("synthetic-upgrade-fixture")
        let raw = WalletMemory()
        let records = ["vault-v1", "unlock-attempts-v1"]
        if mode == "write" {
            guard try FileManager.default.contentsOfDirectory(atPath: path).isEmpty else {
                preconditionFailure("Writer requires an empty fixture directory")
            }
            try Data("synthetic only".utf8).write(to: marker)
        } else {
            guard try Data(contentsOf: marker) == Data("synthetic only".utf8) else { preconditionFailure("Expected synthetic fixture") }
            for account in records {
                let file = dir.appendingPathComponent(account)
                if FileManager.default.fileExists(atPath: file.path) { try raw.insert(Data(contentsOf: file), account: account) }
            }
        }
        let installation = OathInstallationSecurity(keys: OathInstallationKeyFile(directory: dir.appendingPathComponent("Installation")),
            credentials: FixtureCredentialCleanup(allowFresh: mode == "write"))
        let storage = OathInstallationVaultStorage(raw: raw, installation: installation)
        let db = try await OathDatabase.open(at: dir.appendingPathComponent("oath.sqlite"))
        try await OathDataEnvironment.seed(db)
        let vault = OathWalletVault(storage: storage, biometricStore: MemoryBiometrics(), database: db)
        let pin: [UInt8] = [2, 0, 6, 4, 0, 1]
        if mode == "write" {
            try await vault.create(digits: pin, importing: .init(phrase: "synthetic upgrade fixture", language: "english"))
            let profile = try await vault.unlockedProfile()
            let accounts = try await db.accounts(walletID: profile.id.uuidString)
            precondition(accounts.contains { $0.networkID == "polkadot" })
            try JSONEncoder().encode(accounts).write(to: dir.appendingPathComponent("original-accounts.json"))
            for account in records {
                if let bytes = try raw.read(account) { try bytes.write(to: dir.appendingPathComponent(account)) }
            }
            print("Newer writer created an installation-protected PIN wallet with real catalogue network identifiers.")
            return
        }

        let original = try raw.read("vault-v1")
        let envelope = try JSONDecoder().decode(OathVaultEnvelope.self, from: storage.read("vault-v1")!)
        let opened = try envelope.openContents(using: envelope.key(for: pin))
        precondition(opened.wallets.first?.id == envelope.id)
        print("Reader authenticated the same PIN and decrypted the writer's original wallet.")
        let snapshot = try await db.snapshot(walletID: envelope.id.uuidString, currency: "USD")
        let originalAccounts = try JSONDecoder().decode([AccountRecord].self,
            from: Data(contentsOf: dir.appendingPathComponent("original-accounts.json")))
        let supported = originalAccounts.filter { OathImportChain(rawValue: $0.networkID) != nil }
        let extra = AccountRecord(id: envelope.id.uuidString + ":ethereum:123", walletID: envelope.id.uuidString,
            networkID: "ethereum", address: "synthetic-additional-public-address", derivationPath: "synthetic-path", accountIndex: 123)
        let expected = mode == "older" ? supported : originalAccounts + [extra]
        precondition(mode != "older" || supported.count < originalAccounts.count, "Historical catalogue must be smaller")
        precondition(snapshot.accounts.count == expected.count && expected.allSatisfy(snapshot.accounts.contains),
                     "Reader must see exactly its supported accounts")
        do { _ = try await vault.unlock(digits: [9, 9, 9, 9, 9, 9]); preconditionFailure("Wrong PIN accepted") }
        catch OathWalletError.wrongPasscode { }
        let restored = try await vault.unlock(digits: pin)
        let afterUnlock = try await db.accounts(walletID: restored.id.uuidString)
        precondition(restored.id == envelope.id && restored.addresses.count == afterUnlock.count &&
                     expected.allSatisfy(afterUnlock.contains), "Existing accounts and wallet identity must survive unlock")
        // Adding an Ethereum account in the older client also enrolls that
        // public address on supported EVM networks when the modern client returns.
        for account in afterUnlock where !expected.contains(account) {
            precondition(mode == "return" && account.accountIndex == extra.accountIndex &&
                         account.address == extra.address && account.derivationPath == extra.derivationPath &&
                         OathImportChain(rawValue: account.networkID)?.isEVM == true)
        }
        for account in afterUnlock {
            precondition(restored.addresses.contains { $0.accountID == account.id && $0.chain.id == account.networkID &&
                $0.address == account.address && $0.path == account.derivationPath })
        }
        if mode == "older" {
            try await db.importWalletIfNeeded(snapshot.wallet, accounts: [extra])
            try await db.renameWallet(envelope.id.uuidString, name: "Synthetic older edit")
            print("Unmodified older reader opened the wallet and added a public account; wrong PIN rejected.")
        } else {
            precondition(snapshot.wallet.name == "Synthetic older edit")
            print("Current reader recovered every original account and the older reader's edits; wrong PIN rejected.")
        }
        let final = try raw.read("vault-v1")
        precondition(original != nil && final == original, "Reader changed the encrypted wallet")
        for account in records {
            if let bytes = try raw.read(account) { try bytes.write(to: dir.appendingPathComponent(account)) }
        }
    }
}
