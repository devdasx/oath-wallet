import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class ExchangeRateTests: XCTestCase {
    private let observedAt = 1_791_590_400.0
    private func rates(_ values: [String: String] = ["USD": "1", "JOD": "0.709", "EUR": "0.89271638", "JPY": "158.31844252", "KWD": "0.3108137"], offset: Double = 0) -> USDExchangeRates {
        USDExchangeRates(rates: values, observedAt: observedAt + offset, fetchedAt: observedAt + offset + 100, source: "fixture")
    }
    private func fixture() async throws -> (OathDatabase, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathFX-" + UUID().uuidString)
        let url = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "btc", name: "Bitcoin", family: "utxo", symbol: "BTC", decimals: 8, derivationPath: "fixture", logo: "", sortOrder: 0)],
                          assets: [.init(id: "btc", networkID: "btc", reference: "native", name: "Bitcoin", symbol: "BTC", decimals: 8)])
        try await db.importWalletIfNeeded(.init(id: "wallet", name: "Fixture", kind: "hd", vaultReference: "fixture", createdAt: 1),
            accounts: [.init(id: "account", walletID: "wallet", networkID: "btc", address: "public-fixture", derivationPath: "fixture")])
        try await db.saveBalances([.init(accountID: "account", assetID: "btc", networkID: "btc", amountAtomic: "250000000", observedAt: 1, source: "fixture")])
        try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "10.25", observedAt: 1, source: "fixture")])
        return (db, url)
    }

    func testExactLocalConversionAndUSDIdentity() async throws {
        let (db, _) = try await fixture()
        let usd = try await db.snapshot(walletID: "wallet", currency: "USD")
        XCTAssertEqual(usd.totalFiat, Decimal(string: "25.625"))
        XCTAssertTrue(usd.valuationComplete)
        try await db.saveExchangeRates(rates())
        for (code, expected) in [("JOD", "18.168125"), ("JPY", "4056.910089575"), ("KWD", "7.9646010625"), ("EUR", "22.8758572375"), ("USD", "25.625")] {
            try await db.selectDisplayCurrency(code)
            let value = try await db.snapshot(walletID: "wallet", currency: "USD")
            XCTAssertEqual(value.currency, code)
            XCTAssertEqual(value.totalFiat, Decimal(string: expected), code)
            XCTAssertEqual(value.holdings.first?.usdPrice, "10.25")
            XCTAssertTrue(value.valuationComplete)
        }
        let stored = try await db.latestPrice(assetID: "btc", currency: "USD")
        XCTAssertEqual(stored?.value, "10.25")
    }

    func testMissingRateNeverRelabelsUSDAndZeroNeedsNoQuote() async throws {
        let (db, _) = try await fixture()
        let missing = try await db.snapshot(walletID: "wallet", currency: "JOD")
        XCTAssertNil(missing.holdings.first?.price)
        XCTAssertNil(missing.holdings.first?.fiatDisplayValue)
        XCTAssertFalse(missing.valuationComplete)
        do { try await db.selectDisplayCurrency("JOD"); XCTFail("Missing rate must not become a selection") } catch { }
        try await db.saveBalances([.init(accountID: "account", assetID: "btc", networkID: "btc", amountAtomic: "0", observedAt: 2, source: "fixture")])
        let zero = try await db.snapshot(walletID: "wallet", currency: "JOD")
        XCTAssertEqual(zero.holdings.first?.fiatDisplayValue, 0)
        XCTAssertTrue(zero.valuationComplete)
    }

    func testCacheAndPreferenceSurviveReopen() async throws {
        let (db, url) = try await fixture()
        try await db.saveExchangeRates(rates())
        try await db.selectDisplayCurrency("JOD")
        let reopened = try await OathDatabase.open(at: url)
        let cache = try await reopened.exchangeRates()
        let snapshot = try await reopened.snapshot(walletID: "wallet", currency: "EUR")
        XCTAssertEqual(cache, rates())
        XCTAssertEqual(snapshot.currency, "JOD")
        XCTAssertEqual(snapshot.totalFiat, Decimal(string: "18.168125"))
    }

    func testInvalidOrOlderTableCannotDestroyCache() async throws {
        let (db, _) = try await fixture()
        try await db.saveExchangeRates(rates())
        for invalid in [["USD": "2"], ["USD": "1", "JOD": "0"], ["USD": "1", "JOD": "-0.7"], ["USD": "1", "jod": "0.7"], ["USD": "1", "JOD": "NaN"]] {
            do { try await db.saveExchangeRates(rates(invalid)); XCTFail("Accepted invalid rates") } catch { }
            let cache = try await db.exchangeRates()
            XCTAssertEqual(cache, rates())
        }
        do { try await db.saveExchangeRates(rates(offset: -86_400)); XCTFail("Accepted stale table") } catch { }
        let cache = try await db.exchangeRates()
        XCTAssertEqual(cache, rates())
    }

    func testRateCommitAndCurrencySelectionUpdateObservedPortfolio() async throws {
        let (db, _) = try await fixture()
        try await db.setSetting("currency", value: "JOD")
        var stream = db.observeWallet(walletID: "wallet", currency: "USD").makeAsyncIterator()
        let initial = try await stream.next()
        XCTAssertFalse(initial!.valuationComplete)
        try await db.saveExchangeRates(rates())
        let priced = try await stream.next()
        XCTAssertEqual(priced?.totalFiat, Decimal(string: "18.168125"))
        try await db.selectDisplayCurrency("USD")
        let selected = try await stream.next()
        XCTAssertEqual(selected?.totalFiat, Decimal(string: "25.625"))
        try await db.saveExchangeRates(rates(["USD": "1", "JOD": "0.71"], offset: 86_400))
        try await db.selectDisplayCurrency("JOD")
        var next = try await stream.next()
        if next?.currency != "JOD" { next = try await stream.next() }
        XCTAssertEqual(next?.totalFiat, Decimal(string: "18.19375"))
    }

    func testNonUSDMarketIngestionRejectedAtomicallyAndLegacyPriceIgnored() async throws {
        let (db, _) = try await fixture()
        do {
            try await db.savePrices([.init(assetID: "btc", currency: "USD", value: "99", observedAt: 2, source: "fixture"),
                                    .init(assetID: "btc", currency: "JOD", value: "50", observedAt: 2, source: "fixture")])
            XCTFail("Accepted non-USD provider quote")
        } catch { }
        let quote = try await db.latestPrice(assetID: "btc", currency: "USD")
        XCTAssertEqual(quote?.value, "10.25")
        try await db.pool.write { sql in
            try PriceRecord(assetID: "btc", currency: "JOD", value: "999", observedAt: 2, source: "legacy").insert(sql)
        }
        try await db.saveExchangeRates(rates())
        let snapshot = try await db.snapshot(walletID: "wallet", currency: "JOD")
        XCTAssertEqual(snapshot.totalFiat, Decimal(string: "18.168125"))
    }

    func testV5UpgradePreservesWalletAndPreferences() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OathFX-v5-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("test.sqlite")
        let old = try DatabaseQueue(path: url.path)
        try Schema.migrator.migrate(old, upTo: "v5_contacts")
        try await old.write { db in
            try db.execute(sql: "INSERT INTO wallets(id,name,kind,vaultReference,createdAt,backedUp) VALUES(?,?,?,?,?,?)", arguments: ["existing", "Existing", "hd", "fixture", 1, false])
            try SettingRecord(key: "currency", value: "JOD", updatedAt: 1).insert(db)
        }
        try old.close()
        let upgraded = try await OathDatabase.open(at: url)
        let wallets = try await upgraded.wallets()
        let settings = try await upgraded.settings()
        let initialCache = try await upgraded.exchangeRates()
        XCTAssertEqual(wallets.first?.id, "existing")
        XCTAssertEqual(settings["currency"], "JOD")
        XCTAssertNil(initialCache)
        try await upgraded.saveExchangeRates(rates())
        let cache = try await upgraded.exchangeRates()
        XCTAssertEqual(cache, rates())
    }

    func testCacheExpiryClockRollbackAndOverflow() {
        let cache = rates()
        XCTAssertTrue(cache.isFresh(at: Date(timeIntervalSince1970: observedAt + 200)))
        XCTAssertFalse(cache.isFresh(at: Date(timeIntervalSince1970: observedAt + 90_001)))
        XCTAssertFalse(cache.isFresh(at: Date(timeIntervalSince1970: observedAt - 1_000)))
        XCTAssertNil(FiatConversion.multiply(.greatestFiniteMagnitude, 10))
        XCTAssertNil(FiatConversion.multiply(.nan, 1))
    }

    func testCorrectingDeviceClockDoesNotPreventRevalidation() async throws {
        let (db, _) = try await fixture()
        let futureFetch = USDExchangeRates(rates: rates().rates, observedAt: observedAt,
            fetchedAt: observedAt + 10_000, source: "fixture")
        try await db.saveExchangeRates(futureFetch)
        XCTAssertFalse(futureFetch.isFresh(at: Date(timeIntervalSince1970: observedAt + 200)))
        try await db.saveExchangeRates(rates())
        let saved = try await db.exchangeRates()
        XCTAssertEqual(saved, rates())
    }
}
