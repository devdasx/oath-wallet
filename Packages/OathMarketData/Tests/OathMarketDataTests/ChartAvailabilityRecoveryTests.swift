import XCTest
import OathDatabase
@testable import OathMarketData

actor UnavailableExchangeChart: MarketTransport {
    let failure: any Error
    let date: Date
    let live: Bool
    let transport = URLSessionMarketTransport()
    var requests: [URL] = []
    var chart: Data?
    var chartSource: String?
    init(_ failure: any Error, date: Date, live: Bool = false) {
        self.failure = failure; self.date = date; self.live = live
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.exchange.coinbase.com" {
            if url.path.hasSuffix("/stats") { throw MarketDataError.notListed }
            throw failure
        }
        if live, KrakenNativeChart.accepts(url) {
            let data = try await transport.data(from: url)
            chart = data; chartSource = "Kraken"
            return data
        }
        guard url.host == "api.coingecko.com", url.path == "/api/v3/coins/dogecoin/market_chart" else { throw MarketDataError.invalidResponse }
        let data: Data
        if live { data = try await transport.data(from: url) }
        else {
            data = try JSONSerialization.data(withJSONObject: ["prices": [
                [(date.timeIntervalSince1970 - 3600) * 1000, 0.2], [date.timeIntervalSince1970 * 1000, 0.22]]])
        }
        chart = data
        chartSource = "CoinGecko"
        return data
    }
}

@MainActor final class ChartAvailabilityRecoveryTests: XCTestCase {
    private let doge = MarketAsset(id: "dogecoin:native", networkID: "dogecoin", reference: "native", decimals: 8)

    func testUnavailablePrimaryRecoversAndPersistsAnExactNativeChart() async throws {
        for failure in [URLError(.timedOut) as any Error, MarketDataError.rateLimited, MarketDataError.unavailable] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("test.sqlite"), date = Date(timeIntervalSince1970: 1_792_222_000)
            let db = try await OathDatabase.open(at: path), feed = UnavailableExchangeChart(failure, date: date)
            let service = MarketDataService(database: db, transport: feed, now: { date }), asset = doge
            let values = try await withThrowingTaskGroup(of: MarketChart.self) { group in
                for _ in 0..<12 { group.addTask { try await service.chart(for: asset).value } }
                var values: [MarketChart] = []
                for try await value in group { values.append(value) }
                return values
            }
            let result = try XCTUnwrap(values.first)
            XCTAssertEqual(result.points.map(\.close), [0.2, 0.22])
            XCTAssertTrue(values.allSatisfy { $0 == result })
            _ = try await service.chart(for: doge)
            let requests = await feed.requests
            XCTAssertEqual(requests.filter { $0.path.hasSuffix("/candles") }.count, 1)
            XCTAssertEqual(requests.filter { $0.path.hasSuffix("/market_chart") }.count, 1)
            let reopened = try await OathDatabase.open(at: path)
            let saved = try await MarketDataService(database: reopened).cachedChart(for: doge)
            XCTAssertEqual(saved?.value, result)
            let canonical = try await reopened.marketCache(key: "v1.chart." + doge.cacheIdentity)
            XCTAssertEqual(canonical?.source, "CoinGecko")
        }
    }

    func testCancellationAndInvalidResponseDoNotSwitchProviders() async throws {
        for failure in [CancellationError() as any Error, URLError(.cancelled), MarketDataError.invalidResponse] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = UnavailableExchangeChart(failure, date: Date())
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: doge); XCTFail("Unexpected recovery") }
            catch {
                if failure is MarketDataError { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
                else { XCTAssertTrue(error is CancellationError) }
            }
            let requests = await feed.requests
            XCTAssertFalse(requests.contains { $0.host == "api.coingecko.com" })
        }
    }

    func testLiveDogecoinChartWhenPrimaryTimesOut() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGE_CHART_LIVE"] == "1" else { throw XCTSkip("Opt-in public chart read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite")), date = Date()
        let feed = UnavailableExchangeChart(URLError(.timedOut), date: date, live: true)
        let result = try await MarketDataService(database: db, transport: feed, now: { date }).chart(for: doge)
        let raw = await feed.chart
        let source = await feed.chartSource
        let expected = try source == "Kraken" ? KrakenNativeChart.decode(XCTUnwrap(raw), market: .dogecoin, at: date) : MarketDecoding.geckoChart(XCTUnwrap(raw), now: date)
        XCTAssertEqual(result.value, expected)
        XCTAssertGreaterThanOrEqual(result.value.points.count, 24)
        XCTAssertTrue(result.value.points.allSatisfy { $0.close.isFinite && $0.close > 0 })
        print("OATH_DOGE_CHART_LIVE recovered \(result.value.points.count) actual chart points with a primary timeout")
    }
}
