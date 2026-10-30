import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private let bitcoinChartAsset = MarketAsset(id: "bitcoin:native", networkID: "bitcoin", reference: "native", decimals: 8)

private func bitcoinHourlyFixture(at date: Date, pair: String = "XXBTZUSD") throws -> Data {
    let hour = Int(date.timeIntervalSince1970 / 3600) * 3600
    let rows: [[Any]] = (0...24).map { i in
        [hour - (24 - i) * 3600, "100", "125", "90", i == 24 ? "123" : "110", "105", "12", 2]
    }
    return try JSONSerialization.data(withJSONObject: ["error": [], "result": [pair: rows, "last": hour - 3600]])
}

private actor BitcoinChartOutage: MarketTransport {
    let date: Date
    let secondaryFailure: any Error
    let live: Bool
    let wrongPair: Bool
    var requests: [URL] = []
    var response: Data?
    init(date: Date, secondaryFailure: any Error = MarketDataError.rateLimited, live: Bool = false, wrongPair: Bool = false) {
        self.date = date; self.secondaryFailure = secondaryFailure; self.live = live; self.wrongPair = wrongPair
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.exchange.coinbase.com" {
            if url.path.hasSuffix("/stats") { throw MarketDataError.notListed }
            throw URLError(.timedOut)
        }
        if url.host == "api.coingecko.com" { throw secondaryFailure }
        guard url == URL(string: "https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=60")! else { throw MarketDataError.invalidResponse }
        let data = live ? try await URLSessionMarketTransport().data(from: url)
            : try bitcoinHourlyFixture(at: date, pair: wrongPair ? "XDGUSD" : "XXBTZUSD")
        response = data
        return data
    }
}

@MainActor final class BitcoinChartRecoveryTests: XCTestCase {
    func testLocalCooldownStillSelectsIndependentChartProvider() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_792_222_000)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let feed = BitcoinChartOutage(date: date, secondaryFailure: DiagnosticDeferral.publicMarketCooldown)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let chart = try await service.chart(for: bitcoinChartAsset)
        XCTAssertEqual(chart.value.points.count, 24)
        let requests = await feed.requests
        XCTAssertEqual(requests.filter { $0.host == "api.kraken.com" }.count, 1)
    }
    func testBitcoinDoubleOutageRecoversOnceAndReopensExactCompletedCandles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_792_222_000), path = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: path), feed = BitcoinChartOutage(date: date)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let values = try await withThrowingTaskGroup(of: MarketChart.self) { group in
            for _ in 0..<12 { group.addTask { try await service.chart(for: bitcoinChartAsset).value } }
            var results: [MarketChart] = []
            for try await value in group { results.append(value) }
            return results
        }
        let chart = try XCTUnwrap(values.first)
        XCTAssertEqual(chart.points.count, 24)
        XCTAssertTrue(chart.points.allSatisfy { $0.close == 110 && $0.time <= date.timeIntervalSince1970 })
        XCTAssertTrue(values.allSatisfy { $0 == chart })
        XCTAssertEqual(try XCTUnwrap(chart.changePercent), 10, accuracy: 0.0001)
        _ = try await service.chart(for: bitcoinChartAsset)
        let requests = await feed.requests
        for host in ["api.coingecko.com", "api.kraken.com"] {
            XCTAssertEqual(requests.filter { $0.host == host }.count, 1)
        }
        XCTAssertEqual(requests.filter { $0.path.hasSuffix("/candles") }.count, 1)
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: bitcoinChartAsset)
        XCTAssertEqual(saved?.value, chart)
        let entry = try await reopened.marketCache(key: "v1.chart." + bitcoinChartAsset.cacheIdentity)
        XCTAssertEqual(entry?.source, "Kraken")
    }

    func testWrongPairCannotBecomeBitcoinAndExistingChartSurvives() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_792_222_000)
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let prior = MarketChart(points: [.init(time: 100, close: 80), .init(time: 200, close: 85)], changePercent: 6.25)
        try await db.saveMarketCache(.init(key: "v1.chart." + bitcoinChartAsset.cacheIdentity, source: "previous",
            payload: JSONEncoder().encode(prior), fetchedAt: 200))
        let feed = BitcoinChartOutage(date: date, wrongPair: true)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        do { _ = try await service.chart(for: bitcoinChartAsset); XCTFail("Accepted a different market") }
        catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        let saved = try await service.cachedChart(for: bitcoinChartAsset)
        XCTAssertEqual(saved?.value, prior)
        XCTAssertEqual(saved?.fetchedAt.timeIntervalSince1970, 200)
    }

    func testMalformedSecondaryAndCancellationNeverStartAnotherProvider() async throws {
        for failure in [MarketDataError.invalidResponse as any Error, CancellationError(), URLError(.cancelled)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = BitcoinChartOutage(date: Date(), secondaryFailure: failure)
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: bitcoinChartAsset); XCTFail("Unexpected recovery") }
            catch { XCTAssertTrue(error is CancellationError || error as? MarketDataError == .invalidResponse) }
            let requests = await feed.requests
            XCTAssertFalse(requests.contains { $0.host == "api.kraken.com" })
        }
    }

    func testWrappedBitcoinAndWrongDecimalsNeverUseNativeFallback() async throws {
        for asset in [MarketAsset(id: "wrapped", networkID: "bitcoin", reference: "wrapped", decimals: 8),
                      MarketAsset(id: "wrong", networkID: "bitcoin", reference: "native", decimals: 18)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let feed = BitcoinChartOutage(date: Date())
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: asset); XCTFail("Unexpected recovery") }
            catch { /* Deliberately unsupported identity; no native substitution. */ }
            let requests = await feed.requests
            XCTAssertFalse(requests.contains { $0.host == "api.kraken.com" })
        }
    }
}

@MainActor final class BitcoinChartDiagnosticsTests: XCTestCase {
    func testRecoveryPreservesOriginalOutagesInSharedOutbox() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = MarketTestDiagnostics.shared, correlation = UUID()
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let date = Date(timeIntervalSince1970: 1_792_222_000), feed = BitcoinChartOutage(date: Date(timeIntervalSince1970: 1_792_222_000))
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let chart = try await OathDiagnostics.$operationID.withValue(correlation) {
            try await OathDiagnostics.withChain("bitcoin") { try await service.chart(for: bitcoinChartAsset) }
        }
        XCTAssertEqual(chart.value.points.count, 24)
        for _ in 0..<100 {
            if await reports.events(for: correlation).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events(for: correlation)
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains { $0.error.domain == "NSURLErrorDomain" && $0.error.code == -1001 })
        XCTAssertTrue(events.contains { $0.error.domain == "OathMarketData.MarketDataError" && $0.error.code == 3 })
        let operation = try XCTUnwrap(events.first?.operationID)
        XCTAssertEqual(operation, correlation)
        XCTAssertTrue(events.allSatisfy { $0.operationID == operation && $0.context["chain"] == "bitcoin" && $0.privacyFiltered })
    }
}

@MainActor final class BitcoinChartLiveTests: XCTestCase {
    func testLiveBitcoinDoubleOutageRecoveryAndOfflineReopen() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_KRAKEN_LIVE"] == "1" else { throw XCTSkip("Opt-in public Bitcoin chart read") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(), path = folder.appendingPathComponent("test.sqlite")
        let db = try await OathDatabase.open(at: path), feed = BitcoinChartOutage(date: date, live: true)
        let service = MarketDataService(database: db, transport: feed, now: { date })
        let chart = try await service.chart(for: bitcoinChartAsset)
        let bytes = await feed.response
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bytes)) as? [String: Any])
        let result = try XCTUnwrap(root["result"] as? [String: Any])
        let rows = try XCTUnwrap(result["XXBTZUSD"] as? [[Any]])
        let closed = Array(rows.dropLast().suffix(24))
        XCTAssertEqual(chart.value.points.map(\.close), try closed.map { try XCTUnwrap(Double(try XCTUnwrap($0[4] as? String))) })
        XCTAssertEqual(chart.value.points.count, 24)
        XCTAssertTrue(chart.value.points.allSatisfy { $0.close > 0 && $0.time <= date.timeIntervalSince1970 })
        _ = try await service.chart(for: bitcoinChartAsset)
        let requests = await feed.requests
        XCTAssertEqual(requests.filter { $0.host == "api.kraken.com" }.count, 1)
        let reopened = try await OathDatabase.open(at: path)
        let offline = try await MarketDataService(database: reopened).cachedChart(for: bitcoinChartAsset)
        XCTAssertEqual(offline?.value, chart.value)
        print("BITCOIN_CHART_LIVE verifiedClosedCandles=24 fallbackReads=1 offlineReopen=true")
    }
}
