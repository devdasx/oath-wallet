import Foundation
import OathDatabase
import SQLite3

actor BalanceHistoryFailure {
    static let shared = BalanceHistoryFailure()
    var fails = false
    var delayed = false
    func set(_ value: Bool) { fails = value }
    func setDelayed(_ value: Bool) { delayed = value }
    func check() async throws {
        if delayed { try await Task.sleep(for: .milliseconds(500)) }
        if fails { throw OathWalletError.unavailable }
    }
}

/// Real production session + vault orchestration and disk SQLite. Derivation,
/// network and keychain use the host harness fixtures; no app/device is launched.
@main struct CheckBalanceHistoryLifecycle {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BalanceLifecycle-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await OathDataEnvironment.seed(db)
        try await db.setSetting("currency", value: "USD")
        let storage = WalletMemory(), biometrics = MemoryBiometrics()
        let vault = OathWalletVault(storage: storage, biometricStore: biometrics, database: db)
        let pin: [UInt8] = [1, 2, 8, 4, 7, 3]
        try await vault.create(digits: pin, importing: nil)
        let session = OathWalletSession(vault: vault)
        await session.finishedSetup(requiresCustomization: false)
        let wallet = session.wallets[0].id
        func history() async throws -> [BalanceSnapshotRecord] {
            try await db.balanceHistory(walletID: wallet, currency: "USD")
        }
        func appOpenCount() async throws -> Int { try await history().filter { $0.reason == .appOpen }.count }
        check(try await appOpenCount() == 1, "Opening Home must append the first snapshot")
        await session.recordBalanceSnapshot(.homeVisit)
        await session.recordBalanceSnapshot(.homeVisit)
        check(try await history().filter { $0.reason == .homeVisit }.count == 2, "Every visit preserves a distinct entry")
        try await session.refresh()
        check(try await history().filter { $0.reason == .refresh }.count == 1, "Successful refresh appends")
        await BalanceHistoryFailure.shared.set(true)
        do { try await session.refresh(); preconditionFailure("Provider fixture did not fail") }
        catch { checks += 1 }
        check(try await history().filter { $0.reason == .refresh }.count == 2, "Partial/failed refresh still saves committed balances")
        await BalanceHistoryFailure.shared.set(false)
        await BalanceHistoryFailure.shared.setDelayed(true)
        var refreshFinished = false
        let slowRefresh = Task { try await session.refresh(); refreshFinished = true }
        for _ in 0..<100 {
            if try await history().filter({ $0.reason == .refresh }).count == 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(try await history().filter { $0.reason == .refresh }.count == 3 && !refreshFinished,
              "Refresh entry must commit while a slow provider is still loading")
        try await slowRefresh.value
        await BalanceHistoryFailure.shared.setDelayed(false)

        let before = try await appOpenCount()
        session.enteringForeground()
        for _ in 0..<100 {
            if try await appOpenCount() > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(try await appOpenCount() == before + 1, "Foreground appends a snapshot without replacing history")
        await session.lock()
        let locked = try await history().count
        let lockedOpens = try await appOpenCount()
        await session.recordBalanceSnapshot(.homeVisit)
        check(try await history().count == locked, "Locked sessions cannot produce snapshots")
        await session.unlock(pin)
        check(try await appOpenCount() == lockedOpens + 1, "Unlock/reopen appends")
        await session.lock()

        let reopenedDB = try await OathDatabase.open(at: url)
        let reopenedVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: reopenedDB)
        let reopened = OathWalletSession(vault: reopenedVault)
        await reopened.load()
        await reopened.unlock(pin)
        check(try await appOpenCount() == lockedOpens + 2, "New session and database retain and append history")
        try await reopenedDB.setSetting("currency", value: "EUR")
        await reopened.recordBalanceSnapshot(.homeVisit)
        let euro = try await reopenedDB.balanceHistory(walletID: wallet, currency: "EUR")
        check(euro.filter { $0.reason == .homeVisit }.count == 1, "Saved currency controls history even before UI observation arrives")
        check(try await appOpenCount() == lockedOpens + 2, "Currency switch preserves USD history")

        // No Home view is mounted: the production session must persist incoming
        // balances and prices on its own, despite other chains being unavailable.
        try await reopenedDB.setSetting("currency", value: "USD")
        let portfolio = try await reopenedDB.snapshot(walletID: wallet, currency: "USD")
        guard let bitcoin = portfolio.holdings.first(where: { $0.networkID == "bitcoin" && $0.reference == "native" }) else { preconditionFailure("Missing fixture asset") }
        let time = Date().timeIntervalSince1970
        try await reopenedDB.saveBalances([.init(accountID: bitcoin.accountID, assetID: bitcoin.assetID, networkID: "bitcoin", amountAtomic: "100000000", observedAt: time, source: "fixture")])
        try await reopenedDB.savePrices([.init(assetID: bitcoin.assetID, currency: "USD", value: "100", observedAt: time, source: "fixture")])
        try await reopened.refresh()
        let day = BalanceDaySummary.interval(containing: Date())
        func waitForChange(_ amount: Decimal, in session: OathWalletSession) async throws {
            for _ in 0..<400 {
                if session.balanceChange(on: day)?.amount == amount { return }
                try await Task.sleep(for: .milliseconds(5))
            }
            preconditionFailure("Session never published the saved daily comparison")
        }
        let opening = try await reopenedDB.balanceDay(walletID: wallet, currency: "USD", interval: day)
        check(opening.opening?.total == 100 && opening.change?.amount == 0, "Partial wallet starts from the settled displayed balance")
        try await waitForChange(0, in: reopened)
        try await reopenedDB.saveBalances([.init(accountID: bitcoin.accountID, assetID: bitcoin.assetID, networkID: "bitcoin", amountAtomic: "105000000", observedAt: time + 1, source: "fixture")])
        for _ in 0..<200 {
            if try await history().first?.total == 105 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let received = try await reopenedDB.balanceDay(walletID: wallet, currency: "USD", interval: day)
        check(received.change?.amount == 5 && received.change?.percentage == 5, "Off-screen receive saves +5 and +5% without mounting the pill")
        try await waitForChange(5, in: reopened)
        check(reopened.balanceChange(on: day)?.percentage == 5, "Session owns the real +5% comparison without a mounted view")
        for _ in 0..<4 {
            // Re-entering Home after a sheet/navigation is only a visit, not a
            // request to erase/reconstruct the comparison. Also check the value
            // before asynchronous storage work completes.
            let visit = Task { await reopened.recordBalanceSnapshot(.homeVisit); await reopened.refreshBalanceDay() }
            check(reopened.balanceChange(on: day)?.amount == 5, "Opening another screen cannot erase a valid change")
            await visit.value
            check(reopened.balanceChange(on: day)?.amount == 5, "Returning from a sheet preserves the baseline")
        }
        reopened.enteredBackground(delay: .fiveMinutes)
        check(reopened.balanceChange(on: day)?.amount == 5, "App switcher preserves the last measured change")
        reopened.enteringForeground()
        check(reopened.balanceChange(on: day)?.amount == 5, "Foreground does not replace the comparison with loading state")
        await reopened.lock()
        check(reopened.balanceChange(on: day)?.amount == 5, "Lock cancels observation without erasing display metadata")
        await reopened.unlock(pin)
        check(reopened.balanceChange(on: day)?.amount == 5, "Unlock preloads the same real comparison")
        check(try await history().first?.assets()?.isEmpty == false, "Full asset quantities and prices are persisted")
        try await reopenedDB.savePrices([.init(assetID: bitcoin.assetID, currency: "USD", value: "80", observedAt: time + 2, source: "fixture")])
        for _ in 0..<200 {
            if try await history().first?.total == 84 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let repriced = try await reopenedDB.balanceDay(walletID: wallet, currency: "USD", interval: day)
        check(repriced.change?.amount == -16 && repriced.change?.percentage == -16, "Off-screen price changes retain the original daily baseline")
        try await waitForChange(-16, in: reopened)
        check(reopened.balanceChange(on: day)?.percentage == -16, "Off-screen price changes immediately update the retained comparison")
        await reopened.lock()
        let finalDB = try await OathDatabase.open(at: url)
        let finalVault = OathWalletVault(storage: storage, biometricStore: biometrics, database: finalDB)
        let finalSession = OathWalletSession(vault: finalVault)
        await finalSession.load()
        check(finalSession.isLocked && finalSession.balanceChange(on: day)?.amount == -16, "Cold launch preloads the change beneath privacy protection")
        await finalSession.unlock(pin)
        check(finalSession.balanceChange(on: day)?.amount == -16, "Cold unlock needs no pill observation to show the real change")
        let otherWallet = try await finalSession.addWallet(requestID: UUID())
        check(finalSession.balanceDaySummary?.walletID == otherWallet && finalSession.balanceChange(on: day)?.amount == 0,
              "Another wallet never inherits the previous wallet's loss")
        try await finalSession.selectWallet(UUID(uuidString: wallet)!)
        check(finalSession.balanceChange(on: day)?.amount == -16, "Switching back restores its own daily opening")
        let tomorrow = BalanceDaySummary.interval(containing: day.end.addingTimeInterval(1))
        check(finalSession.balanceChange(on: tomorrow) == nil, "A previous day's loss cannot be presented as today's change")
        try await finalDB.setSetting("currency", value: "EUR")
        for _ in 0..<400 {
            if finalSession.portfolio?.currency == "EUR", finalSession.balanceDaySummary?.currency == "EUR" { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        check(finalSession.balanceDaySummary?.currency == "EUR" && finalSession.balanceChange(on: day)?.amount == 0,
              "Changing currency cannot reuse the dollar loss")
        try await finalDB.setSetting("currency", value: "USD")
        try await waitForChange(-16, in: finalSession)
        check(finalSession.balanceDaySummary?.currency == "USD", "Switching currency back restores its saved daily opening")
        await finalSession.lock()
        await reopened.unlock(pin)

        // Inject a real SQLite failure at the persistence boundary. It must not
        // fail refresh or lock the session; the shared diagnostics handles it.
        var connection: OpaquePointer?
        check(sqlite3_open(url.path, &connection) == SQLITE_OK, "Open isolated fixture")
        defer { sqlite3_close(connection) }
        check(sqlite3_exec(connection, "CREATE TRIGGER history_failure BEFORE INSERT ON balanceSnapshots BEGIN SELECT RAISE(ABORT, 'synthetic storage failure'); END;", nil, nil, nil) == SQLITE_OK, "Install failure fixture")
        try await reopened.refresh()
        check(reopened.isUnlocked, "History failure cannot block wallet refresh")
        check(reopened.balanceChange(on: day)?.amount == -16, "A failed snapshot write cannot erase the last real comparison")
        check(sqlite3_exec(connection, "DROP TRIGGER history_failure", nil, nil, nil) == SQLITE_OK, "Remove failure fixture")
        await reopened.lock()
        print("Balance history lifecycle: \(checks) checks passed (production session and SQLite; fixture providers, no device or network).")
    }
}
