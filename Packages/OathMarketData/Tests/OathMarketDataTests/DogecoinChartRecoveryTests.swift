import XCTest
import OathDatabase
@testable import OathMarketData

private actor DogecoinChartOutage: MarketTransport {
    let date: Date
    let live: Bool
    let secondaryFailure: any Error
    var requests: [URL] = []
    var response: Data?
    init(date: Date, live: Bool = false, secondaryFailure: any Error = MarketDataError.rateLimited) {
        self.date = date; self.live = live; self.secondaryFailure = secondaryFailure
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.exchange.coinbase.com" { throw URLError(.timedOut) }
        if url.host == "api.coingecko.com" { throw secondaryFailure }
        guard url.host == "api.kraken.com" else { throw MarketDataError.invalidResponse }
        let result = live ? try await URLSessionMarketTransport().data(from: url) : try dogecoinHourlyFixture(at: date)
        response = result
        return result
    }
}

func dogecoinHourlyFixture(at date: Date) throws -> Data {
    let hour = Int(date.timeIntervalSince1970 / 3600) * 3600
    let rows: [[Any]] = (0...24).map { i in
        [hour - (24 - i) * 3600, "0.20", "0.24", "0.19", "0.22", "0.21", "1000.0", 10]
    }
    return try JSONSerialization.data(withJSONObject: ["error": [], "result": ["XDGUSD": rows, "last": hour - 3600]])
}

@MainActor final class DogecoinChartRecoveryTests: XCTestCase {
    private let asset = MarketAsset(id: "dogecoin:native", networkID: "dogecoin", reference: "native", decimals: 8)
    func testRejectsStaleWrongPairBrokenIntervalsAndInvalidPrices() throws {
        let date = Date(timeIntervalSince1970: 1_792_222_000)
        let data = try dogecoinHourlyFixture(at: date)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertThrowsError(try KrakenNativeChart.decode(data, market: .dogecoin, at: date.addingTimeInterval(3600)))
        for mutation in 0..<7 {
            var root = original, result = try XCTUnwrap(original["result"] as? [String: Any])
            var rows = try XCTUnwrap(result["XDGUSD"] as? [[Any]])
            switch mutation {
            case 0: result["XXBTZUSD"] = result.removeValue(forKey: "XDGUSD")
            case 1: rows[1][0] = rows[0][0]; result["XDGUSD"] = rows
            case 2: rows[1][4] = "NaN"; result["XDGUSD"] = rows
            case 3: rows[1][4] = "0.30"; result["XDGUSD"] = rows // Above the high.
            case 4: rows[1][6] = "-1"; result["XDGUSD"] = rows
            case 5: result["last"] = 0
            default: root["error"] = ["EGeneral:Invalid arguments"]
            }
            root["result"] = result
            XCTAssertThrowsError(try KrakenNativeChart.decode(JSONSerialization.data(withJSONObject: root), market: .dogecoin, at: date))
        }
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "token", networkID: "bnb", reference: "DOGE", decimals: 8)))
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "wrong", networkID: "dogecoin", reference: "native", decimals: 18)))
    }
    func testDoubleProviderFailureRecoversWithoutRepeatingRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_792_222_000), path = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: path), feed = DogecoinChartOutage(date: date)
        let service = MarketDataService(database: db, transport: feed, now: { date }), asset = asset
        let values = try await withThrowingTaskGroup(of: MarketChart.self) { group in
            for _ in 0..<12 { group.addTask { try await service.chart(for: asset).value } }
            var results: [MarketChart] = []
            for try await result in group { results.append(result) }
            return results
        }
        let chart = try XCTUnwrap(values.first)
        XCTAssertEqual(chart.points.count, 24)
        XCTAssertTrue(values.allSatisfy { $0 == chart })
        XCTAssertTrue(chart.points.allSatisfy { $0.time <= date.timeIntervalSince1970 && $0.close == 0.22 })
        XCTAssertEqual(try XCTUnwrap(chart.changePercent), 10, accuracy: 0.0001)
        _ = try await service.chart(for: asset)
        let requests = await feed.requests
        XCTAssertEqual(requests.filter { $0.host == "api.kraken.com" }.count, 1)
        XCTAssertEqual(requests.filter { $0.host == "api.coingecko.com" }.count, 1)
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: asset)
        XCTAssertEqual(saved?.value, chart)
        let canonical = try await reopened.marketCache(key: "v1.chart." + asset.cacheIdentity)
        XCTAssertEqual(canonical?.source, "Kraken")
    }
    func testMalformedSecondaryAndCancellationNeverStartAnotherProvider() async throws {
        for failure in [MarketDataError.invalidResponse as any Error, CancellationError(), URLError(.cancelled)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = DogecoinChartOutage(date: Date(), secondaryFailure: failure)
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: asset); XCTFail("Unexpected recovery") }
            catch { XCTAssertTrue(error is CancellationError || error as? MarketDataError == .invalidResponse) }
            let requests = await feed.requests
            XCTAssertFalse(requests.contains { $0.host == "api.kraken.com" })
        }
    }
    func testLiveDoubleOutageRecoversVerifiedDogecoinCandles() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGE_KRAKEN_LIVE"] == "1" else { throw XCTSkip("Opt-in public chart read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = DogecoinChartOutage(date: date, live: true)
        let chart = try await MarketDataService(database: db, transport: feed, now: { date }).chart(for: asset)
        XCTAssertEqual(chart.value.points.count, 24)
        XCTAssertTrue(chart.value.points.allSatisfy { $0.close > 0 && $0.time <= date.timeIntervalSince1970 })
        let raw = await feed.response
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(raw)) as? [String: Any])
        let result = try XCTUnwrap(root["result"] as? [String: Any])
        let rows = try XCTUnwrap(result["XDGUSD"] as? [[Any]])
        let closed = Array(rows.dropLast().suffix(24))
        XCTAssertEqual(chart.value.points.map(\.close), try closed.map { try XCTUnwrap(Double(try XCTUnwrap($0[4] as? String))) })
        print("OATH_DOGE_KRAKEN_LIVE: verified 24 closed DOGE/USD candles with Coinbase timeout and CoinGecko 429")
    }
}
