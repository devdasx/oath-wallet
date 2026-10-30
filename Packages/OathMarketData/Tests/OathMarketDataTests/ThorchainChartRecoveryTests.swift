import XCTest
import OathDatabase
@testable import OathMarketData

private actor RuneChartTransport: MarketTransport {
    let now: Date
    let primaryError: MarketDataError
    var requests: [URL] = []
    var fallbackData: Data?
    func replaceFallback(with data: Data) { fallbackData = data }
    init(now: Date, primaryError: MarketDataError = .rateLimited) {
        self.now = now; self.primaryError = primaryError
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.coingecko.com" { throw primaryError }
        guard url.host == "gateway.liquify.com",
              url.path == "/chain/thorchain_midgard/v2/history/rune" else {
            throw MarketDataError.invalidResponse
        }
        return try fallbackData ?? runeHistory(now: now)
    }
}

private actor LiveRuneChartFallback: MarketTransport {
    private let live = URLSessionMarketTransport()
    var historyRequests = 0
    func data(from url: URL) async throws -> Data {
        if url.host == "api.coingecko.com" { throw MarketDataError.rateLimited }
        guard ThorchainChart.accepts(url) else { throw MarketDataError.invalidResponse }
        historyRequests += 1
        return try await live.data(from: url)
    }
}

private actor CancelledRuneChart: MarketTransport {
    var requests = 0
    func data(from url: URL) async throws -> Data {
        requests += 1
        throw URLError(.cancelled)
    }
}

private func runeHistory(now: Date, offset: Int = 0, price: String = "2") throws -> Data {
    let end = Int(now.timeIntervalSince1970) / 3600 * 3600 + offset
    return try JSONSerialization.data(withJSONObject: [
        "meta": ["startTime": String(end - 25 * 3600), "endTime": String(end)],
        "intervals": (0..<25).map { index in
            ["startTime": String(end - (25-index)*3600),
             "endTime": String(end - (24-index)*3600), "runePriceUSD": price]
        }
    ])
}

@MainActor final class ThorchainChartRecoveryTests: XCTestCase {
    private let rune = MarketAsset(id: "thorchain:native", networkID: "thorchain", reference: "native", decimals: 8)

    func testRateLimitedRuneChartRecoversAndPersistsWithoutRefreshingOldTimestamps() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), now = Date()
        let db = try await OathDatabase.open(at: path), transport = RuneChartTransport(now: now)
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let recovered = try await service.chart(for: rune)
        XCTAssertGreaterThan(recovered.value.points.count, 20)
        XCTAssertTrue(recovered.value.points.allSatisfy { $0.close == 2 && $0.time <= now.timeIntervalSince1970 })
        XCTAssertEqual(recovered.value.changePercent, 0)
        let again = try await service.chart(for: rune)
        XCTAssertEqual(again.value, recovered.value)
        XCTAssertEqual(again.fetchedAt, recovered.fetchedAt)
        let requests = await transport.requests
        XCTAssertEqual(requests.filter { $0.host == "api.coingecko.com" }.count, 1)
        XCTAssertEqual(requests.filter { $0.host == "gateway.liquify.com" }.count, 1)
        let entry = try await db.marketCache(key: "v1.chart." + rune.cacheIdentity)
        XCTAssertEqual(entry?.source, "THORChain Midgard")
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: rune)
        XCTAssertEqual(saved?.value, recovered.value)
        XCTAssertEqual(saved?.fetchedAt, recovered.fetchedAt)
    }

    func testRuneFallbackNeverPricesOtherTokensOrMalformedPrimaryData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        for (asset, error) in [
            (rune, MarketDataError.invalidResponse),
            (MarketAsset(id: "thorchain:tcy", networkID: "thorchain", reference: "tcy", decimals: 8), .rateLimited),
            (MarketAsset(id: "tron:native", networkID: "tron", reference: "native", decimals: 6), .rateLimited)
        ] {
            let transport = RuneChartTransport(now: Date(), primaryError: error)
            let service = MarketDataService(database: db, transport: transport)
            do { _ = try await service.chart(for: asset); XCTFail("Accepted unavailable or invalid data") }
            catch { }
            let requests = await transport.requests
            XCTAssertFalse(requests.contains { $0.host == "gateway.liquify.com" })
        }
    }

    func testMalformedOrStaleFallbackCannotOverwriteSavedChart() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite")), now = Date()
        let transport = RuneChartTransport(now: now)
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let good = try await service.chart(for: rune)
        await transport.replaceFallback(with: try runeHistory(now: now, offset: -3600))
        do { _ = try await service.chart(for: rune, force: true); XCTFail("Accepted stale history") }
        catch { XCTAssertEqual(error as? MarketDataError, .invalidResponse) }
        let saved = try await service.cachedChart(for: rune)
        XCTAssertEqual(saved?.value, good.value)
        XCTAssertEqual(saved?.fetchedAt, good.fetchedAt)
    }

    func testCancellationNeverStartsFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let transport = CancelledRuneChart()
        do { _ = try await MarketDataService(database: db, transport: transport).chart(for: rune); XCTFail("Ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests, 1)
    }

    func testHistoryValidatesCompleteClosedHoursAndStrictPositivePrices() throws {
        let now = Date(timeIntervalSince1970: 1_792_217_837)
        let bytes = try runeHistory(now: now)
        let chart = try ThorchainChart.decode(bytes, at: now)
        XCTAssertEqual(chart.points.count, 25)
        XCTAssertEqual(chart.points.last!.time - chart.points.first!.time, 86400)
        for offset in [-86400, -3600, 3600, 86400] {
            XCTAssertThrowsError(try ThorchainChart.decode(runeHistory(now: now, offset: offset), at: now))
        }
        for price in ["0", "-1", "NaN", "inf", "1junk", "1e999", "true"] {
            XCTAssertThrowsError(try ThorchainChart.decode(runeHistory(now: now, price: price), at: now))
        }
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let intervals = try XCTUnwrap(valid["intervals"] as? [[String: String]])
        for rows in [[], Array(intervals.dropLast()), intervals + [intervals[0]], [intervals[0]] + Array(intervals.dropLast()), Array(intervals.reversed())] {
            var bad = valid; bad["intervals"] = rows
            XCTAssertThrowsError(try ThorchainChart.decode(JSONSerialization.data(withJSONObject: bad), at: now))
        }
        for time in [Double.nan, .infinity, -1, 253_402_300_800] {
            XCTAssertThrowsError(try ThorchainChart.url(at: Date(timeIntervalSince1970: time)))
        }
    }

    func testLiveRateLimitRecoveryThroughProductionTransport() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RUNE_CHART_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public Midgard request; CoinGecko failure is injected")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), db = try await OathDatabase.open(at: path)
        let transport = LiveRuneChartFallback(), service = MarketDataService(database: db, transport: transport)
        let result = try await service.chart(for: rune)
        XCTAssertEqual(result.value.points.count, 25)
        XCTAssertTrue(result.value.points.allSatisfy { $0.close > 0 && $0.close.isFinite })
        XCTAssertLessThan(Date().timeIntervalSince1970 - result.value.points.last!.time, 3600)
        let requests = await transport.historyRequests; XCTAssertEqual(requests, 1)
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedChart(for: rune)
        XCTAssertEqual(saved?.value, result.value)
        XCTAssertEqual(saved?.fetchedAt, result.fetchedAt)
        print("RUNE_CHART_LIVE: injected CoinGecko 429; 25 validated public hourly prices; persisted and reopened")
    }
}
