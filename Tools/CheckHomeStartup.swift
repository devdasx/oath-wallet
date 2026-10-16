import Foundation
import OathDatabase

/// Real vault/session/display preparation and disk SQLite; public synthetic
/// identities, in-memory authentication and no-network providers from the host
/// harness. No SwiftUI view is needed to prepare the first visible Home frame.
@main struct CheckHomeStartup {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeStartup-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("wallet.sqlite")
        let database = try await OathDatabase.open(at: url)
        try await OathDataEnvironment.seed(database)
        try await database.setSetting("currency", value: "USD")
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: database)
        let pin: [UInt8] = [1, 2, 3, 4, 5, 6]
        try await vault.create(digits: pin, importing: nil)
        let wallet = try await vault.unlockedProfile().id.uuidString
        let snapshot = try await database.snapshot(walletID: wallet, currency: "USD")
        let account = snapshot.accounts.first { $0.networkID == "ethereum" }!
        let asset = snapshot.holdings.first { $0.accountID == account.id && $0.reference == "native" }!
        var batch = SyncBatch(cursor: .init(accountID: account.id, stream: "host-fixture", cursor: "1", updatedAt: 100),
                              expectedCursor: nil)
        batch.balances = [.init(accountID: account.id, assetID: asset.assetID, networkID: "ethereum",
                               amountAtomic: "1000000000000000000", observedAt: 100, source: "fixture")]
        for index in 0..<65 {
            let id = "public-fixture-\(index)", time = Double(100 + index)
            batch.transactions.append(.init(id: id, networkID: "ethereum", hash: id, state: "confirmed", timestamp: time, updatedAt: time))
            batch.activity.append(.init(id: id, walletID: wallet, accountID: account.id, networkID: "ethereum",
                transactionID: id, assetID: asset.assetID, direction: "incoming", amountAtomic: "1",
                counterparty: "public-fixture", timestamp: time))
        }
        try await database.apply(batch)
        try await database.savePrices([.init(assetID: asset.assetID, currency: "USD", value: "100", observedAt: 100, source: "fixture")])
        var filter = PortfolioFilter(); filter.hidesZeroBalances = true
        try await database.savePortfolioFilter(filter, walletID: wallet)
        await vault.lock()

        func assertReady(_ session: OathWalletSession) {
            check(session.homePortfolio.hasPrepared, "Home must be prepared without mounting a view")
            check(session.homePortfolio.walletID == wallet, "Presentation belongs to the selected wallet")
            check(session.homePortfolio.rows.contains { $0.holding.assetID == asset.assetID && $0.holding.amountAtomic == "1000000000000000000" }, "Saved balance is ready without any network response")
            check(session.portfolio?.assetFilter.hidesZeroBalances == true, "Saved wallet filter is retained")
            check(session.homeHistory?.items.count == 51, "Local index preload stays bounded to a page and lookahead")
            let history = OathChainActivityModel(seed: session.homeHistory)
            check(history.items.count == 50 && history.hasMore && !history.loading, "History first frame is populated before its observer starts")
            check(history.items.first?.id == "public-fixture-64", "History keeps newest-first order")
        }

        // Cold launch, with SQL reopened and the same encrypted vault storage.
        let disk = try await OathDatabase.open(at: url)
        let coldVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: disk)
        let cold = OathWalletSession(vault: coldVault)
        await cold.load()
        check(cold.isLocked, "Loading saved display data must not unlock the vault")
        assertReady(cold)
        do { _ = try await coldVault.unlockedProfile(); preconditionFailure("Preload unlocked signing") }
        catch { checks += 1 }
        await cold.unlock([9, 9, 9, 9, 9, 9])
        check(cold.isLocked, "Wrong passcode still blocks access")
        assertReady(cold)
        await cold.unlock(pin)
        check(cold.isUnlocked, "Correct passcode unlocks")
        assertReady(cold)
        let visible = cold.homePortfolio.rows
        await cold.lock()
        check(cold.homePortfolio.rows == visible, "Relocking preserves the last display beneath privacy protection")
        await cold.unlock(pin)
        assertReady(cold)

        await biometrics.allowEnrollment()
        guard case .enabled = try await coldVault.enableBiometrics(strings: .current) else {
            preconditionFailure("Fixture biometric enrollment failed")
        }
        try await cold.refreshSecurity()
        await cold.lock()
        await cold.unlockWithBiometrics()
        check(cold.isUnlocked, "Biometric success unlocks with prepared display data")
        assertReady(cold)

        let grant = try await coldVault.authorizeSecurityChange(digits: pin)
        try await coldVault.setPasscode(nil, authorization: grant)
        let unsecuredVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: disk)
        let unsecured = OathWalletSession(vault: unsecuredVault)
        await unsecured.load()
        check(unsecured.isUnlocked && !unsecured.security.passcodeEnabled, "No-passcode startup uses the same local index")
        assertReady(unsecured)
        let other = try await unsecured.addWallet(requestID: UUID())
        check(unsecured.homePortfolio.walletID == other, "Wallet creation prepares the selected wallet")
        let otherAccounts = Set((unsecured.portfolio?.accounts ?? []).map(\.id))
        check(!otherAccounts.isEmpty && unsecured.homePortfolio.rows.allSatisfy { otherAccounts.contains($0.holding.accountID) }, "No previous wallet assets bleed into the new wallet")
        check(unsecured.homeHistory?.walletID == other && unsecured.homeHistory?.items.isEmpty == true, "An actually empty new wallet does not inherit old history")
        try await unsecured.selectWallet(UUID(uuidString: wallet)!)
        assertReady(unsecured)
        let beforeBackground = unsecured.homePortfolio.rows
        unsecured.enteredBackground(delay: .immediately)
        unsecured.enteringForeground()
        check(unsecured.isUnlocked && unsecured.homePortfolio.rows == beforeBackground, "No-passcode background/foreground retains saved assets")
        assertReady(unsecured)
        print("PASS: \(checks) startup checks: cold SQL reopen, PIN, wrong PIN, Face ID fixture, no passcode, wallet switches, background/foreground, bounded history, persisted filters, and locked signing access")
    }
}
