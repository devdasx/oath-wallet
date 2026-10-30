import XCTest
import OathDatabase
@testable import OathMarketData

/// Explicitly hold one provider reply until another service has committed.
/// This reproduces refreshes from independent screens sharing one database.
private actor OrderedQuoteFeed: MarketTransport {
    let amount: String
    let code: String
    var held: Bool
    var quoteRequests = 0
    var pending: CheckedContinuation<Void, Never>?

    init(amount: String, held: Bool = false, code: String = "ETH") { self.amount = amount; self.held = held; self.code = code }

    func data(from url: URL) async throws -> Data {
        guard url.host == "api.coinbase.com", url.path == "/v2/prices/\(code)-USD/spot" else {
            throw MarketDataError.notListed
        }
        quoteRequests += 1
        if held { await withCheckedContinuation { pending = $0 } }
        try Task.checkCancellation()
        return Data("{\"data\":{\"amount\":\"\(amount)\",\"base\":\"\(code)\",\"currency\":\"USD\"}}".utf8)
    }

    func release() { held = false; pending?.resume(); pending = nil }
}

@MainActor final class MarketCacheRaceTests: XCTestCase {
    func testOlderFallbackChartReturnsNewerCanonicalChart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let date = Date(timeIntervalSince1970: 1_791_740_000)
        let asset = MarketAsset(id: "tron:native", networkID: "tron", reference: "native", decimals: 6)
        let winner = MarketChart(points: [.init(time: date.timeIntervalSince1970, close: 2),
            .init(time: date.timeIntervalSince1970 + 60, close: 3)], changePercent: 50)
        try await database.saveMarketCache(.init(key: "v1.chart." + asset.cacheIdentity, source: "CoinGecko",
            payload: JSONEncoder().encode(winner), fetchedAt: date.timeIntervalSince1970 + 60))
        let service = MarketDataService(database: database, transport: OlderChartFeed(date: date), now: { date })
        let value = try await service.chart(for: asset, force: true)
        XCTAssertEqual(value.value, winner)
        XCTAssertEqual(value.fetchedAt, date.addingTimeInterval(60))
        let cached = try await service.cachedChart(for: asset)
        XCTAssertEqual(cached?.value, winner)
    }

    func testLateOlderQuoteReturnsCommittedWinnerAndDoesNotBackOffNextRefresh() async throws {
        try await verifyQuoteRace(network: "ethereum", decimals: 18)
    }

    func testBitcoinAndBitcoinCashLateQuotesPreserveWinnerWithoutStaleSync() async throws {
        XCTAssertEqual((StoreError.staleSync as NSError).code, 3)
        for network in ["bitcoin", "bitcoincash"] {
            try await verifyQuoteRace(network: network, decimals: 8)
        }
    }

    private func verifyQuoteRace(network: String, decimals: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("test.sqlite")
        let database = try await OathDatabase.open(at: url)
        let code = try XCTUnwrap(MarketIdentity.native[network]?.coinbase)
        let asset = MarketAsset(id: network + ":native", networkID: network, reference: "native", decimals: decimals)
        try await database.seed(networks: [.init(id: network, name: network, family: "fixture", symbol: code,
            decimals: decimals, derivationPath: "fixture", logo: "", sortOrder: 0)], assets: [
                .init(id: asset.id, networkID: asset.networkID, reference: "native", name: network, symbol: code, decimals: decimals)])

        let olderDate = Date(timeIntervalSince1970: 1_791_740_000)
        let newerDate = olderDate.addingTimeInterval(10)
        let delayed = OrderedQuoteFeed(amount: "2000", held: true, code: code)
        let recent = OrderedQuoteFeed(amount: "2500", code: code)
        let first = MarketDataService(database: database, transport: delayed, now: { olderDate })
        let second = MarketDataService(database: database, transport: recent, now: { newerDate })
        let slowRequest = Task { try await first.quote(for: asset, force: true) }
        for _ in 0..<200 {
            if await delayed.pending != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let isWaiting = await delayed.pending != nil
        XCTAssertTrue(isWaiting, "The older request must be in flight before the newer commit")
        do {
            let winner = try await second.quote(for: asset, force: true)
            XCTAssertEqual(winner.value.usd, "2500")
            await delayed.release()
            let late = try await slowRequest.value
            XCTAssertEqual(late.value, winner.value)
            XCTAssertEqual(late.fetchedAt, newerDate, "Do not relabel the winning quote's freshness")

            let again = try await first.quote(for: asset, force: true)
            XCTAssertEqual(again.value, winner.value)
            let requestCount = await delayed.quoteRequests
            XCTAssertEqual(requestCount, 2, "A superseded success must not activate failure backoff")

            let reopened = try await OathDatabase.open(at: url)
            let saved = try await reopened.latestPrice(assetID: asset.id, currency: "USD")
            XCTAssertEqual(saved?.value, "2500")
            XCTAssertEqual(saved?.observedAt, newerDate.timeIntervalSince1970)
        } catch {
            await delayed.release()
            _ = await slowRequest.result
            throw error
        }
    }
}

private struct OlderChartFeed: MarketTransport {
    let date: Date
    func data(from url: URL) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["prices": [
            [(date.timeIntervalSince1970 - 3600) * 1000, 1.0],
            [date.timeIntervalSince1970 * 1000, 1.5]]])
    }
}
