import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor TronChartOutage: MarketTransport {
    let date: Date
    let live: Bool
    let secondaryFailure: any Error
    var requests: [URL] = []
    var response: Data?
    var primaryData: Data?
    func setPrimaryData(_ data: Data) { primaryData = data }
    var fallbackData: Data?
    var fallbackError: (any Error)?
    func replaceFallback(data: Data? = nil, error: (any Error)? = nil) { fallbackData = data; fallbackError = error }
    init(date: Date, live: Bool = false, secondaryFailure: any Error = MarketDataError.rateLimited) {
        self.date = date; self.live = live; self.secondaryFailure = secondaryFailure
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.exchange.coinbase.com" { throw URLError(.timedOut) }
        if url.host == "api.coingecko.com" {
            if let primaryData { return primaryData }
            throw secondaryFailure
        }
        guard url.host == "api.kraken.com" else { throw MarketDataError.invalidResponse }
        if let fallbackError { throw fallbackError }
        let result = live ? try await URLSessionMarketTransport().data(from: url) : try fallbackData ?? tronHourlyFixture(at: date)
        response = result
        return result
    }
}

func tronHourlyFixture(at date: Date) throws -> Data {
    let hour = Int(date.timeIntervalSince1970 / 3600) * 3600
    let rows: [[Any]] = (0...24).map { i in
        [hour - (24 - i) * 3600, "0.20", "0.24", "0.19", "0.22", "0.21", "1000.0", 10]
    }
    return try JSONSerialization.data(withJSONObject: ["error": [], "result": ["TRXUSD": rows, "last": hour - 3600]])
}

private actor TronChartReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

@MainActor final class TronChartRecoveryTests: XCTestCase {
    private let asset = MarketAsset(id: "tron:native", networkID: "tron", reference: "native", decimals: 6)
    func testHealthyPrimaryDoesNotRequestFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = TronChartOutage(date: date)
        let prices: [[Double]] = [[(date.timeIntervalSince1970 - 3600) * 1000, 0.30], [date.timeIntervalSince1970 * 1000, 0.33]]
        await feed.setPrimaryData(try JSONSerialization.data(withJSONObject: ["prices": prices]))
        let result = try await MarketDataService(database: db, transport: feed, now: { date }).chart(for: asset)
        XCTAssertEqual(result.value.points.map(\.close), [0.30, 0.33])
        let requests = await feed.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.host, "api.coingecko.com")
    }
    func testRejectsStaleWrongPairBrokenIntervalsAndInvalidPrices() throws {
        let date = Date(timeIntervalSince1970: 1_792_222_000)
        let data = try tronHourlyFixture(at: date)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertThrowsError(try KrakenNativeChart.decode(data, market: .tron, at: date.addingTimeInterval(3600)))
        for mutation in 0..<7 {
            var root = original, result = try XCTUnwrap(original["result"] as? [String: Any])
            var rows = try XCTUnwrap(result["TRXUSD"] as? [[Any]])
            switch mutation {
            case 0: result["XXBTZUSD"] = result.removeValue(forKey: "TRXUSD")
            case 1: rows[1][0] = rows[0][0]; result["TRXUSD"] = rows
            case 2: rows[1][4] = "NaN"; result["TRXUSD"] = rows
            case 3: rows[1][4] = "0.30"; result["TRXUSD"] = rows // Above the high.
            case 4: rows[1][6] = "-1"; result["TRXUSD"] = rows
            case 5: result["last"] = 0
            default: root["error"] = ["EGeneral:Invalid arguments"]
            }
            root["result"] = result
            XCTAssertThrowsError(try KrakenNativeChart.decode(JSONSerialization.data(withJSONObject: root), market: .tron, at: date))
        }
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "token", networkID: "bnb", reference: "TRX", decimals: 6)))
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "wrong", networkID: "tron", reference: "native", decimals: 18)))
        XCTAssertFalse(KrakenNativeChart.supports(.init(id: "token", networkID: "tron", reference: "TRX", decimals: 6)))
    }
    func testRateLimitedNativeChartRecoversWithoutRepeatingRequests() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_792_222_000), path = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: path), feed = TronChartOutage(date: date)
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
        XCTAssertFalse(requests.contains { $0.host == "api.exchange.coinbase.com" }, "TRX has no Coinbase Exchange candle product")
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
            let feed = TronChartOutage(date: Date(), secondaryFailure: failure)
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: asset); XCTFail("Unexpected recovery") }
            catch { XCTAssertTrue(error is CancellationError || error as? MarketDataError == .invalidResponse) }
            let requests = await feed.requests
            XCTAssertFalse(requests.contains { $0.host == "api.kraken.com" })
        }
    }
    func testStaleMalformedAndUnavailableFallbackPreserveSavedChart() async throws {
        for failure in 0..<3 {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite")), date = Date()
            let feed = TronChartOutage(date: date)
            let service = MarketDataService(database: db, transport: feed, now: { date })
            let good = try await service.chart(for: asset)
            switch failure {
            case 0: await feed.replaceFallback(data: try tronHourlyFixture(at: date.addingTimeInterval(-3600)))
            case 1: await feed.replaceFallback(data: Data("invalid json".utf8))
            default: await feed.replaceFallback(error: MarketDataError.unavailable)
            }
            do { _ = try await service.chart(for: asset, force: true); XCTFail("Invalid fallback accepted") }
            catch { XCTAssertFalse(error is CancellationError) }
            let saved = try await service.cachedChart(for: asset)
            XCTAssertEqual(saved?.value, good.value)
            XCTAssertEqual(saved?.fetchedAt, good.fetchedAt)
        }
    }
    func testRecoveredChartStillReportsOriginalRateLimitWithSafeCorrelation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = TronChartReports(), operation = UUID()
        OathDiagnostics.configure(file: folder.appendingPathComponent("events.json"), transport: reports)
        let date = Date(), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let service = MarketDataService(database: db, transport: TronChartOutage(date: date), now: { date })
        _ = try await OathDiagnostics.$operationID.withValue(operation) { try await service.chart(for: asset) }
        for _ in 0..<100 {
            await OathDiagnostics.flush()
            if await reports.events.filter({ $0.operationID == operation }).count >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events.filter { $0.operationID == operation }
        XCTAssertTrue(events.contains { $0.operation == "market_load" && $0.error.message == "rateLimited" })
        XCTAssertTrue(events.contains { $0.operation == "kraken_chart_fallback" && $0.error.message == "rateLimited" })
        XCTAssertTrue(events.allSatisfy { $0.context["chain"] == "tron" && $0.privacyFiltered })
        let serialized = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(serialized.contains("https://"))
        XCTAssertFalse(serialized.contains(asset.id))
    }
    func testLiveRateLimitRecoversVerifiedTronCandles() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRX_KRAKEN_LIVE"] == "1" else { throw XCTSkip("Opt-in public chart read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = TronChartOutage(date: date, live: true)
        let chart = try await MarketDataService(database: db, transport: feed, now: { date }).chart(for: asset)
        XCTAssertEqual(chart.value.points.count, 24)
        XCTAssertTrue(chart.value.points.allSatisfy { $0.close > 0 && $0.time <= date.timeIntervalSince1970 })
        let raw = await feed.response
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(raw)) as? [String: Any])
        let result = try XCTUnwrap(root["result"] as? [String: Any])
        let rows = try XCTUnwrap(result["TRXUSD"] as? [[Any]])
        let closed = Array(rows.dropLast().suffix(24))
        XCTAssertEqual(chart.value.points.map(\.close), try closed.map { try XCTUnwrap(Double(try XCTUnwrap($0[4] as? String))) })
        print("OATH_TRX_KRAKEN_LIVE: verified 24 closed TRX/USD candles with injected CoinGecko 429")
    }
}
