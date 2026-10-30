import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private let xlayerChartAsset = MarketAsset(id: "xlayer:native", networkID: "xlayer", reference: "native", decimals: 18)

private actor XLayerChartFeed: MarketTransport {
    let date: Date
    let failure: any Error
    let wrongPair: Bool
    let live: Bool
    var requests: [URL] = []
    var response: Data?
    init(date: Date, failure: any Error = MarketDataError.rateLimited, wrongPair: Bool = false, live: Bool = false) {
        self.date = date; self.failure = failure; self.wrongPair = wrongPair; self.live = live
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.exchange.coinbase.com" { throw MarketDataError.notListed }
        if url.host == "api.coingecko.com" { throw failure }
        guard url == URL(string: "https://api.kraken.com/0/public/OHLC?pair=OKBUSD&interval=60") else { throw MarketDataError.invalidResponse }
        let data: Data
        if live { data = try await URLSessionMarketTransport().data(from: url) }
        else {
            let hour = Int(date.timeIntervalSince1970 / 3600) * 3600
            let rows: [[Any]] = (0...24).map { i in
                [hour - (24 - i) * 3600, "100", "125", "90", i == 24 ? "123" : "110", "105", "12", 2]
            }
            data = try JSONSerialization.data(withJSONObject: ["error": [], "result": [wrongPair ? "OKBUSDT" : "OKBUSD": rows, "last": hour - 3600]])
        }
        response = data
        return data
    }
}

@MainActor final class XLayerChartRecoveryTests: XCTestCase {
    func testExactNativeOKBRecoversCoalescesPersistsAndReportsOriginalFailure() async throws {
        let reports = MarketTestDiagnostics.shared, id = UUID()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), date = Date(timeIntervalSince1970: 1_792_222_000)
        let db = try await OathDatabase.open(at: path), feed = XLayerChartFeed(date: date)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let charts = try await OathDiagnostics.$operationID.withValue(id) {
            try await withThrowingTaskGroup(of: MarketChart.self) { group in
                for _ in 0..<12 { group.addTask { try await service.chart(for: xlayerChartAsset).value } }
                var values: [MarketChart] = []
                for try await value in group { values.append(value) }
                return values
            }
        }
        let chart = try XCTUnwrap(charts.first)
        XCTAssertTrue(charts.allSatisfy { $0 == chart })
        XCTAssertEqual(chart.points.count, 24)
        XCTAssertTrue(chart.points.allSatisfy { $0.close == 110 })
        XCTAssertEqual(try XCTUnwrap(chart.changePercent), 10, accuracy: 0.0001)
        _ = try await service.chart(for: xlayerChartAsset)
        let requests = await feed.requests
        XCTAssertEqual(requests.filter { $0.host == "api.kraken.com" }.count, 1)
        let reopened = try await OathDatabase.open(at: path)
        let cached = try await MarketDataService(database: reopened).cachedChart(for: xlayerChartAsset)
        XCTAssertEqual(cached?.value, chart)
        for _ in 0..<100 {
            if await reports.events(for: id).contains(where: { $0.operation == "kraken_chart_fallback" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events(for: id)
        XCTAssertTrue(events.contains { $0.operation == "market_load" && $0.error.code == 3 })
        XCTAssertTrue(events.contains { $0.operation == "kraken_chart_fallback" })
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "xlayer" && $0.privacyFiltered })
    }

    func testWrongQuoteCurrencyPreservesExistingChart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let previous = MarketChart(points: [.init(time: 100, close: 1), .init(time: 200, close: 2)], changePercent: 100)
        try await db.saveMarketCache(.init(key: "v1.chart." + xlayerChartAsset.cacheIdentity, source: "previous", payload: JSONEncoder().encode(previous), fetchedAt: 200))
        let service = MarketDataService(database: db, transport: XLayerChartFeed(date: date, wrongPair: true), now: { date })
        do { _ = try await service.chart(for: xlayerChartAsset); XCTFail("USDT chart accepted as USD") }
        catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        let saved = try await service.cachedChart(for: xlayerChartAsset)
        XCTAssertEqual(saved?.value, previous)
        XCTAssertEqual(saved?.fetchedAt.timeIntervalSince1970, 200)
    }

    func testNativeMappingRejectsTokensWrongDecimalsAndPreservesCancellation() async throws {
        XCTAssertTrue(KrakenNativeChart.supports(xlayerChartAsset))
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "wrong", networkID: "xlayer", reference: "native", decimals: 8)))
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "token", networkID: "xlayer", reference: "0x1234", decimals: 18)))
        for failure in [CancellationError() as any Error, URLError(.cancelled), MarketDataError.invalidResponse] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = XLayerChartFeed(date: Date(), failure: failure)
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: xlayerChartAsset); XCTFail("Failure ignored") }
            catch { XCTAssertTrue(error is CancellationError || error as? MarketDataError == .invalidResponse) }
            let requests = await feed.requests
            XCTAssertFalse(requests.contains { $0.host == "api.kraken.com" })
        }
    }

    func testLiveOKBUSDRecoveryAndOfflineReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_XLAYER_CHART_LIVE"] == "1" else { throw XCTSkip("Opt-in public OKB/USD chart read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), date = Date()
        let db = try await OathDatabase.open(at: path), feed = XLayerChartFeed(date: date, live: true)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let result = try await service.chart(for: xlayerChartAsset)
        let bytes = await feed.response
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bytes)) as? [String: Any])
        let values = try XCTUnwrap(root["result"] as? [String: Any])
        let rows = try XCTUnwrap(values["OKBUSD"] as? [[Any]])
        let closed = Array(rows.dropLast().suffix(24))
        XCTAssertEqual(result.value.points.map(\.close), try closed.map { try XCTUnwrap(Double(try XCTUnwrap($0[4] as? String))) })
        XCTAssertEqual(result.value.points.count, 24)
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: xlayerChartAsset)
        XCTAssertEqual(saved?.value, result.value)
        print("XLAYER_CHART_LIVE pair=OKBUSD completedCandles=24 exactPrices=true persisted=true")
    }
}
