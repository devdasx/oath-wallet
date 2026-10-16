import XCTest
import GRDB
@testable import OathDatabase

@MainActor final class MarketCacheTests: XCTestCase {
    private func fixture() async throws -> (OathDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OathMarketDB-" + UUID().uuidString).appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: url)
        try await db.seed(networks: [.init(id: "eth", name: "Ethereum", family: "evm", symbol: "ETH", decimals: 18,
            derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [
                .init(id: "native", networkID: "eth", reference: "native", name: "Ether", symbol: "ETH", decimals: 18),
                .init(id: "token", networkID: "eth", reference: "fixture", name: "Token", symbol: "ETH", decimals: 6)])
        for id in ["a", "b"] {
            try await db.importWalletIfNeeded(.init(id: id, name: id, kind: "hd", vaultReference: id, createdAt: 1),
                accounts: [.init(id: id, walletID: id, networkID: "eth", address: "fixture-" + id, derivationPath: "fixture")])
        }
        return (db, url)
    }
    private func entry(_ value: String = "saved", time: Double = 100) -> MarketCacheEntry {
        MarketCacheEntry(key: "quote.native", source: "Coinbase", payload: Data(value.utf8), fetchedAt: time)
    }
    private func price(_ asset: String = "native", time: Double = 100) -> PriceRecord {
        .init(assetID: asset, currency: "USD", value: "123.456789", observedAt: time, source: "Coinbase")
    }

    func testCacheAndUSDPriceCommitTogetherSurviveReopenAndReset() async throws {
        let (db, url) = try await fixture()
        try await db.saveMarketCache(entry(), price: price())
        let reopened = try await OathDatabase.open(at: url)
        let cache = try await reopened.marketCache(key: "quote.native")
        let quote = try await reopened.latestPrice(assetID: "native", currency: "USD")
        XCTAssertEqual(cache, entry()); XCTAssertEqual(quote, price())
        let reset = try await reopened.beginWalletReset()
        try await reopened.eraseWalletData(resetID: reset)
        try await reopened.finishWalletReset(resetID: reset)
        let surviving = try await reopened.marketCache(key: "quote.native")
        let survivingPrice = try await reopened.latestPrice(assetID: "native", currency: "USD")
        XCTAssertEqual(surviving, entry()); XCTAssertEqual(survivingPrice, price())
    }
    func testBadOlderAndCrossAssetWritesDoNotReplaceGoodCache() async throws {
        let (db, _) = try await fixture()
        try await db.saveMarketCache(entry(), price: price())
        do { try await db.saveMarketCache(entry("older", time: 99), price: price(time: 99)); XCTFail() }
        catch { XCTAssertEqual(error as? StoreError, .staleSync) }
        do { try await db.saveMarketCache(entry("broken", time: 101), price: price("missing", time: 101)); XCTFail() } catch { }
        do { try await db.saveMarketCache(entry("mismatch", time: 102), price: price(time: 103)); XCTFail() } catch { }
        let after = try await db.marketCache(key: "quote.native")
        XCTAssertEqual(after, entry())
        let stored = try await db.latestPrice(assetID: "native", currency: "USD")
        XCTAssertEqual(stored, price())
    }
    func testPriceCacheDoesNotGrowWithoutBound() async throws {
        let (db, _) = try await fixture()
        for time in 1...270 {
            try await db.saveMarketCache(entry(time: Double(time)), price: price(time: Double(time)))
        }
        let count = try await db.pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM prices WHERE assetID='native'") }
        XCTAssertEqual(count, 256)
    }
    func testAssetHistoryIsScopedToWalletAccountAndAssetAndPagesWithoutDuplicates() async throws {
        let (db, _) = try await fixture()
        for account in ["a", "b"] {
            var batch = SyncBatch(cursor: .init(accountID: account, stream: "history", cursor: "one", updatedAt: 1), expectedCursor: nil)
            for index in 0..<6 {
                let id = "\(account)-\(index)"
                batch.transactions.append(.init(id: id, networkID: "eth", hash: id, state: "confirmed", timestamp: 1, updatedAt: 1))
                batch.activity.append(.init(id: id, walletID: account, accountID: account, networkID: "eth", transactionID: id,
                    assetID: index < 4 ? "native" : "token", direction: "incoming", amountAtomic: "1", counterparty: "fixture", timestamp: 1))
            }
            _ = try await db.apply(batch)
        }
        let page1 = try await db.assetHistory(walletID: "a", accountID: "a", assetID: "native", limit: 2)
        let last = try XCTUnwrap(page1.last)
        let page2 = try await db.assetHistory(walletID: "a", accountID: "a", assetID: "native",
            before: .init(timestamp: last.timestamp, id: last.id), limit: 2)
        XCTAssertEqual(Set((page1 + page2).map(\.id)).count, 4)
        XCTAssertTrue((page1 + page2).allSatisfy { $0.accountID == "a" && $0.assetID == "native" })
        let crossWallet = try await db.assetHistory(walletID: "a", accountID: "b", assetID: "native")
        XCTAssertTrue(crossWallet.isEmpty)
    }
    func testMigrationFromV8PreservesExistingWalletsAndPrices() async throws {
        let (db, url) = try await fixture()
        try await db.savePrices([price()])
        try await db.pool.write {
            try $0.execute(sql: "DROP TABLE publicMarketCache; DELETE FROM grdb_migrations WHERE identifier='v9_public_market_cache'")
        }
        let reopened = try await OathDatabase.open(at: url)
        try await reopened.saveMarketCache(entry())
        let wallets = try await reopened.wallets()
        let quote = try await reopened.latestPrice(assetID: "native", currency: "USD")
        XCTAssertEqual(wallets.count, 2); XCTAssertEqual(quote, price())
    }
}
