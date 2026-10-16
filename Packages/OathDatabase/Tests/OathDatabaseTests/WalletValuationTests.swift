import XCTest
@testable import OathDatabase

@MainActor final class WalletValuationTests: XCTestCase {
    private let ids: Set<String> = ["one", "two", "empty"]

    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathWalletValues-" + UUID().uuidString)
            .appendingPathComponent("wallet.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "ethereum", name: "Ethereum", family: "evm", symbol: "ETH",
            decimals: 18, derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [
                .init(id: "eth", networkID: "ethereum", reference: "native", name: "Ethereum", symbol: "ETH", decimals: 18),
                .init(id: "token", networkID: "ethereum", reference: "0x0000000000000000000000000000000000000002",
                      name: "Example token", symbol: "TEST", decimals: 6)
            ])
        for id in ["one", "two", "empty"] {
            try await db.importWalletIfNeeded(.init(id: id, name: id, kind: "hd", vaultReference: id, createdAt: 1),
                accounts: [.init(id: id + "account", walletID: id, networkID: "ethereum",
                    address: "0x0000000000000000000000000000000000000001", derivationPath: "fixture")])
        }
        try await db.saveBalances([
            .init(accountID: "oneaccount", assetID: "eth", networkID: "ethereum", amountAtomic: "1000000000000000000", observedAt: 1, source: "fixture"),
            .init(accountID: "oneaccount", assetID: "token", networkID: "ethereum", amountAtomic: "2000000", observedAt: 1, source: "fixture"),
            .init(accountID: "twoaccount", assetID: "eth", networkID: "ethereum", amountAtomic: "3000000000000000000", observedAt: 1, source: "fixture")
        ])
        try await db.savePrices([
            .init(assetID: "eth", currency: "USD", value: "10", observedAt: 1, source: "fixture"),
            .init(assetID: "token", currency: "USD", value: "3", observedAt: 1, source: "fixture")
        ])
        try await db.setSetting("activeWalletID", value: "two")
        return (db, url)
    }

    func testIndependentTotalsIncludeTokensAndMatchHomeWithoutSwitchingWallet() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let values = try await db.walletValuations(walletIDs: ids, currency: "USD")
        XCTAssertEqual(values.map(\.id), ["one", "two", "empty"])
        XCTAssertEqual(values.map(\.totalFiat), [16, 30, 0])
        XCTAssertFalse(values[2].valuationComplete, "An unscanned zero fallback must remain distinguishable internally")
        for value in values {
            let home = try await db.snapshot(walletID: value.id, currency: "USD")
            XCTAssertEqual(value, WalletValuation(snapshot: home))
        }
        let settings = try await db.settings()
        XCTAssertEqual(settings["activeWalletID"], "two")
    }

    func testMembershipAndDeletedWalletsCannotLeakIntoResults() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.reconcileWalletLifecycle([.init(id: "two", deletedAt: 10)])
        let scoped = try await db.walletValuations(walletIDs: ["one", "two", "missing"], currency: "USD")
        XCTAssertEqual(scoped.map(\.id), ["one"])
        let none = try await db.walletValuations(walletIDs: [], currency: "USD")
        XCTAssertTrue(none.isEmpty)
    }

    func testCurrencyAndTotalsSurviveOfflineReopen() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "JOD": "0.709"], observedAt: 1, fetchedAt: 1, source: "fixture"))
        try await db.selectDisplayCurrency("JOD")
        let reopened = try await OathDatabase.open(at: url)
        let values = try await reopened.walletValuations(walletIDs: ids, currency: "USD")
        XCTAssertTrue(values.allSatisfy { $0.currency == "JOD" })
        XCTAssertEqual(values.map(\.totalFiat), [Decimal(string: "11.344")!, Decimal(string: "21.27")!, 0])
    }

    func testObservationUpdatesInactiveBalancePricesCurrencyAndDeletion() async throws {
        let (db, url) = try await fixture()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var stream = db.observeWalletValuations(walletIDs: ids, currency: "USD").makeAsyncIterator()
        let initial = try await stream.next()
        XCTAssertEqual(initial?.first?.totalFiat, 16)
        try await db.saveBalances([.init(accountID: "oneaccount", assetID: "eth", networkID: "ethereum",
            amountAtomic: "2000000000000000000", observedAt: 2, source: "fixture")])
        let balance = try await stream.next()
        XCTAssertEqual(balance?.first?.totalFiat, 26)
        XCTAssertEqual(balance?.first { $0.id == "two" }?.totalFiat, 30)
        try await db.savePrices([.init(assetID: "eth", currency: "USD", value: "20", observedAt: 2, source: "fixture")])
        let prices = try await stream.next()
        XCTAssertEqual(prices?.first?.totalFiat, 46)
        try await db.saveExchangeRates(.init(rates: ["USD": "1", "JOD": "0.709"], observedAt: 1, fetchedAt: 1, source: "fixture"))
        try await db.selectDisplayCurrency("JOD")
        let converted = try await stream.next()
        XCTAssertEqual(converted?.first?.currency, "JOD")
        XCTAssertEqual(converted?.first?.totalFiat, Decimal(string: "32.614"))
        try await db.reconcileWalletLifecycle([.init(id: "one", deletedAt: 10)])
        let deleted = try await stream.next()
        XCTAssertEqual(deleted?.map(\.id), ["two", "empty"])
    }
}
