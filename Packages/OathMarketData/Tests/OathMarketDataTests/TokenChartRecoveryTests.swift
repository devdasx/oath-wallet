import XCTest
import OathDatabase
import OathDiagnostics
@testable import OathMarketData

private actor TokenChartFeed: MarketTransport {
    let asset: MarketAsset
    let network: String
    let date: Date
    var requests: [URL] = []
    var primaryFailure: (any Error)?
    var poolFailure: (any Error)?
    var candleFailure: (any Error)?
    func setFailures(primary: (any Error)? = nil, pool: (any Error)? = nil, candles: (any Error)? = nil) {
        primaryFailure = primary; poolFailure = pool; candleFailure = candles
    }
    init(asset: MarketAsset, network: String, date: Date) {
        self.asset = asset; self.network = network; self.date = date
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.coingecko.com" { throw primaryFailure ?? MarketDataError.rateLimited }
        if url.host == "api.exchange.coinbase.com", url.path == "/currencies" {
            // A valid directory without this token, not a failed catalog read.
            return Data(#"[{"id":"BTC","supported_networks":[]}]"#.utf8)
        }
        guard url.host == "api.geckoterminal.com" else { throw MarketDataError.notListed }
        if url.path.hasSuffix("/pools") {
            if let poolFailure { throw poolFailure }
            return try TokenChartFixtures.pools(asset, network: network)
        }
        if let candleFailure { throw candleFailure }
        return try TokenChartFixtures.candles(asset, at: date)
    }
}

enum TokenChartFixtures {
    static let pool = "0x1111111111111111111111111111111111111111"
    static let other = "0x2222222222222222222222222222222222222222"
    static func pools(_ asset: MarketAsset, network: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "data": [["id": network + "_" + pool, "type": "pool",
                "attributes": ["address": pool, "reserve_in_usd": "1000000"],
                "relationships": ["base_token": ["data": ["id": network + "_" + other, "type": "token"]],
                    "quote_token": ["data": ["id": network + "_" + asset.reference, "type": "token"]]]]],
            "included": [["id": network + "_" + asset.reference, "type": "token",
                "attributes": ["address": asset.reference, "decimals": asset.decimals]]]
        ])
    }
    static func candles(_ asset: MarketAsset, at date: Date) throws -> Data {
        let hour = floor(date.timeIntervalSince1970 / 3600) * 3600
        let candles = (0...24).map { index -> [Double] in
            [hour - Double(index) * 3600, 1, 1.1, 0.9, 1.01, 100]
        }
        return try JSONSerialization.data(withJSONObject: [
            "data": ["type": "ohlcv_request_response", "attributes": ["ohlcv_list": candles]],
            "meta": ["base": ["address": asset.reference], "quote": ["address": other]]
        ])
    }
}

@MainActor final class TokenChartRecoveryTests: XCTestCase {
    func testTokenChartRecoversWithoutCoinbaseOrCoinGeckoAndPersists() async throws {
        for (network, terminal, decimals) in [("bnb", "bsc", 18), ("arbitrum", "arbitrum", 6)] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("test.sqlite")
            let database = try await OathDatabase.open(at: path)
            let asset = MarketAsset(id: network + ":fixture", networkID: network,
                reference: "0x3333333333333333333333333333333333333333", decimals: decimals)
            let date = Date(timeIntervalSince1970: 1_791_740_000)
            let feed = TokenChartFeed(asset: asset, network: terminal, date: date)
            let service = MarketDataService(database: database, transport: feed, now: { date })
            let charts = try await withThrowingTaskGroup(of: CachedMarketValue<MarketChart>.self) { group in
                for _ in 0..<8 { group.addTask { try await service.chart(for: asset) } }
                var values: [CachedMarketValue<MarketChart>] = []
                for try await value in group { values.append(value) }
                return values
            }
            let chart = try XCTUnwrap(charts.first)
            XCTAssertTrue(charts.allSatisfy { $0.value == chart.value })
            XCTAssertEqual(chart.value.points.count, 24)
            XCTAssertEqual(chart.value.changePercent ?? 0, 1, accuracy: 0.0001)
            let calls = await feed.requests
            XCTAssertEqual(calls.filter { $0.host == "api.geckoterminal.com" }.count, 2)
            let candles = try XCTUnwrap(calls.first { $0.path.contains("/ohlcv/") })
            let query = URLComponents(url: candles, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "token" }?.value, asset.reference,
                "The requested asset is the pool's quote token; never chart the other token")
            XCTAssertEqual(query.first { $0.name == "currency" }?.value, "usd")
            _ = try await service.chart(for: asset)
            let cachedCalls = await feed.requests
            XCTAssertEqual(cachedCalls, calls)
            let reopened = try await OathDatabase.open(at: path)
            let persisted = try await MarketDataService(database: reopened, transport: feed, now: { date }).cachedChart(for: asset)
            XCTAssertEqual(persisted?.value, chart.value)
        }
    }

    func testCancellationAndMalformedPrimaryNeverStartPoolFallback() async throws {
        for failure in [CancellationError() as any Error, URLError(.cancelled), MarketDataError.invalidResponse] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let asset = MarketAsset(id: "fixture", networkID: "bnb", reference: "0x3333333333333333333333333333333333333333", decimals: 18)
            let feed = TokenChartFeed(asset: asset, network: "bsc", date: Date())
            await feed.setFailures(primary: failure)
            do { _ = try await MarketDataService(database: db, transport: feed).chart(for: asset); XCTFail("Invalid recovery") }
            catch { XCTAssertTrue(error is CancellationError || error as? MarketDataError == .invalidResponse) }
            let calls = await feed.requests
            XCTAssertFalse(calls.contains { $0.host == "api.geckoterminal.com" })
        }
    }

    func testInterruptedPoolAndCandleReadsRetryWithoutNewOutageDeadline() async throws {
        for stage in ["pool", "candles"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
            let asset = MarketAsset(id: "fixture", networkID: "bnb", reference: "0x3333333333333333333333333333333333333333", decimals: 18)
            let date = Date(), feed = TokenChartFeed(asset: asset, network: "bsc", date: Date())
            await feed.setFailures(pool: stage == "pool" ? URLError(.cancelled) : nil,
                                   candles: stage == "candles" ? URLError(.cancelled) : nil)
            let service = MarketDataService(database: db, transport: feed, now: { date })
            do { _ = try await service.chart(for: asset); XCTFail("Ignored cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            let saved = try await service.cachedChart(for: asset)
            XCTAssertNil(saved)
            await feed.setFailures()
            let recovered = try await service.chart(for: asset)
            XCTAssertEqual(recovered.value.points.count, 24)
        }
    }
}

@MainActor final class TokenPoolChartValidationTests: XCTestCase {
    let asset = MarketAsset(id: "fixture", networkID: "bnb", reference: "0x3333333333333333333333333333333333333333", decimals: 18)
    let date = Date(timeIntervalSince1970: 1_791_740_000)

    func testSelectionRejectsWrongNetworkContractAndDecimals() throws {
        let valid = try TokenChartFixtures.pools(asset, network: "bsc")
        let text = String(decoding: valid, as: UTF8.self)
        let mutations = [text.replacingOccurrences(of: "bsc_", with: "eth_"),
            text.replacingOccurrences(of: asset.reference, with: "0x4444444444444444444444444444444444444444"),
            text.replacingOccurrences(of: "\"decimals\":18", with: "\"decimals\":6"),
            text.replacingOccurrences(of: "\"decimals\":18", with: "\"decimals\":true")]
        for mutated in mutations {
            XCTAssertNotEqual(mutated, text)
            XCTAssertThrowsError(try TokenPoolChart.select(Data(mutated.utf8), for: asset))
        }
    }
    func testDeepestPoolIsSelectedAndDustPoolsAreRejected() throws {
        let original = try JSONSerialization.jsonObject(with: TokenChartFixtures.pools(asset, network: "bsc")) as! [String: Any]
        var root = original
        let first = (root["data"] as! [[String: Any]])[0]
        var deep = first
        deep["id"] = "bsc_0x5555555555555555555555555555555555555555"
        deep["attributes"] = ["address": "0x5555555555555555555555555555555555555555", "reserve_in_usd": "2000000"]
        root["data"] = [first, deep]
        let selection = try TokenPoolChart.select(JSONSerialization.data(withJSONObject: root), for: asset)
        XCTAssertEqual(selection.pool, "0x5555555555555555555555555555555555555555")
        let dust = String(decoding: try TokenChartFixtures.pools(asset, network: "bsc"), as: UTF8.self).replacingOccurrences(of: "1000000", with: "50")
        XCTAssertThrowsError(try TokenPoolChart.select(Data(dust.utf8), for: asset)) { XCTAssertEqual($0 as? MarketDataError, .notListed) }
    }
    func testNativeAndUnsupportedAddressesCannotUseTokenPoolFallback() throws {
        for item in [MarketAsset(id: "native", networkID: "bnb", reference: "native", decimals: 18),
                     MarketAsset(id: "malformed", networkID: "bnb", reference: asset.reference + "/extra", decimals: 18),
                     MarketAsset(id: "wrong-network", networkID: "solana", reference: asset.reference, decimals: 18)] {
            XCTAssertNil(TokenPoolChart.network(for: item))
            XCTAssertThrowsError(try TokenPoolChart.poolsURL(for: item))
        }
    }
    func testSingletonPoolIdentifiersDoNotRelaxTokenAddressValidation() throws {
        let poolID = "0x" + String(repeating: "a", count: 64)
        let fixture = String(decoding: try TokenChartFixtures.pools(asset, network: "bsc"), as: UTF8.self)
            .replacingOccurrences(of: TokenChartFixtures.pool, with: poolID)
        let selection = try TokenPoolChart.select(Data(fixture.utf8), for: asset)
        XCTAssertEqual(selection.pool, poolID)
        XCTAssertTrue(try TokenPoolChart.candlesURL(for: asset, selection: selection, at: date).path.contains(poolID))
        XCTAssertNil(TokenPoolChart.network(for: MarketAsset(id: "invalid-token", networkID: "bnb", reference: poolID, decimals: 18)))
    }
    func testCandlesRejectWrongSideFutureDuplicateMalformedAndStaleData() throws {
        let selection = try TokenPoolChart.select(TokenChartFixtures.pools(asset, network: "bsc"), for: asset)
        let original = try JSONSerialization.jsonObject(with: TokenChartFixtures.candles(asset, at: date)) as! [String: Any]
        for kind in ["wrong-side", "future", "duplicate", "negative", "ohlc", "boolean", "stale"] {
            var root = original, body = root["data"] as! [String: Any], attributes = body["attributes"] as! [String: Any]
            var rows = attributes["ohlcv_list"] as! [[Any]]
            switch kind {
            case "wrong-side": root["meta"] = ["base": ["address": TokenChartFixtures.other], "quote": ["address": asset.reference]]
            case "future": rows[0][0] = (rows[0][0] as! Double) + 7200
            case "duplicate": rows[1] = rows[0]
            case "negative": rows[1][4] = -1
            case "ohlc": rows[1][3] = 100
            case "boolean": rows[1][4] = true
            default: rows = rows.map { var row = $0; row[0] = (row[0] as! Double) - 86_400; return row }
            }
            attributes["ohlcv_list"] = rows; body["attributes"] = attributes; root["data"] = body
            XCTAssertThrowsError(try TokenPoolChart.decode(JSONSerialization.data(withJSONObject: root), for: asset, selection: selection, at: date), kind)
        }
    }
    func testSparseChartDoesNotInventTwentyFourHourPercentage() throws {
        let selection = try TokenPoolChart.select(TokenChartFixtures.pools(asset, network: "bsc"), for: asset)
        var root = try JSONSerialization.jsonObject(with: TokenChartFixtures.candles(asset, at: date)) as! [String: Any]
        var body = root["data"] as! [String: Any], attributes = body["attributes"] as! [String: Any]
        var rows = attributes["ohlcv_list"] as! [[Double]]
        rows.remove(at: 5); attributes["ohlcv_list"] = rows; body["attributes"] = attributes; root["data"] = body
        let chart = try TokenPoolChart.decode(JSONSerialization.data(withJSONObject: root), for: asset, selection: selection, at: date)
        XCTAssertEqual(chart.points.count, 23)
        XCTAssertNil(chart.changePercent)
    }
    func testRequestedTokenMetadataWorksForEitherPoolSide() throws {
        for selection in [
            TokenPoolChart.Selection(network: "bsc", pool: TokenChartFixtures.pool, base: asset.reference, quote: TokenChartFixtures.other),
            TokenPoolChart.Selection(network: "bsc", pool: TokenChartFixtures.pool, base: TokenChartFixtures.other, quote: asset.reference)
        ] {
            let chart = try TokenPoolChart.decode(TokenChartFixtures.candles(asset, at: date), for: asset, selection: selection, at: date)
            XCTAssertEqual(chart.points.count, 24)
            XCTAssertTrue(chart.points.allSatisfy { $0.close == 1.01 })
        }
    }
}

private actor LiveTokenChartFeed: MarketTransport {
    let live = URLSessionMarketTransport()
    var responses: [URL: Data] = [:]
    func data(from url: URL) async throws -> Data {
        if url.host == "api.coingecko.com" { throw MarketDataError.rateLimited }
        guard url.host == "api.geckoterminal.com" else { throw MarketDataError.notListed }
        let data = try await live.data(from: url)
        responses[url] = data
        return data
    }
}

@MainActor final class TokenChartLiveTests: XCTestCase {
    func testLiveBNBArbitrumAndAvalanchePoolChartsWithPrimaryThrottled() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TOKEN_CHART_LIVE"] == "1" else { throw XCTSkip("Opt-in public token market reads") }
        for (network, reference, decimals) in [
            ("bnb", "0x55d398326f99059ff775485246999027b3197955", 18),
            ("arbitrum", "0xaf88d065e77c8cc2239327c5edb3a432268e5831", 6),
            ("avalanche", "0xb97ef9ef8734c71904d8002f8b6bc66dd9c48a6e", 6)
        ] {
            if let selected = ProcessInfo.processInfo.environment["OATH_TOKEN_CHART_NETWORK"] {
                guard ["bnb", "arbitrum", "avalanche"].contains(selected) else { XCTFail("Unknown live test network"); return }
                if selected != network { continue }
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let path = folder.appendingPathComponent("test.sqlite"), date = Date()
            let db = try await OathDatabase.open(at: path), feed = LiveTokenChartFeed()
            let asset = MarketAsset(id: network + ":" + reference, networkID: network, reference: reference, decimals: decimals)
            let service = MarketDataService(database: db, transport: feed, now: { date })
            let result = try await service.chart(for: asset)
            XCTAssertGreaterThanOrEqual(result.value.points.count, 2)
            let responses = await feed.responses
            XCTAssertEqual(responses.count, 2)
            let candles = try XCTUnwrap(responses.first { $0.key.path.contains("/ohlcv/") }?.value)
            let root = try JSONSerialization.jsonObject(with: candles) as! [String: Any]
            let rows = ((root["data"] as! [String: Any])["attributes"] as! [String: Any])["ohlcv_list"] as! [[Double]]
            let end = floor(date.timeIntervalSince1970 / 3600) * 3600
            let closes = rows.reversed().filter { $0[0] >= end - 86_400 && $0[0] < end }.map { $0[4] }
            XCTAssertEqual(result.value.points.map(\.close), closes)
            let reopened = try await OathDatabase.open(at: path)
            let cached = try await MarketDataService(database: reopened).cachedChart(for: asset)
            XCTAssertEqual(cached?.value, result.value)
            print("TOKEN_CHART_LIVE network=\(network) completedCandles=\(closes.count) exactContract=true persisted=true")
        }
    }
}

@MainActor final class TokenChartDiagnosticsTests: XCTestCase {
    func testAbsentPrimaryListingsAreNotReportedAsOutagesWhenPoolRecovers() async throws {
        let reports = MarketTestDiagnostics.shared, id = UUID(), date = Date()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let asset = MarketAsset(id: "fixture", networkID: "bnb", reference: "0x3333333333333333333333333333333333333333", decimals: 18)
        let feed = TokenChartFeed(asset: asset, network: "bsc", date: date)
        await feed.setFailures(primary: MarketDataError.notListed)
        let value = try await OathDiagnostics.$operationID.withValue(id) {
            try await MarketDataService(database: db, transport: feed, now: { date }).chart(for: asset)
        }
        XCTAssertEqual(value.value.points.count, 24)
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events(for: id)
        XCTAssertTrue(events.isEmpty, "Unexpected fixture reports: \(events.map { $0.operation + ":" + $0.error.message })")
    }

    func testRecoveredChartRetainsOriginalFailureCorrelationAndPrivacy() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let reports = MarketTestDiagnostics.shared
        let database = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let asset = MarketAsset(id: "private-fixture-id", networkID: "bnb", reference: "0x3333333333333333333333333333333333333333", decimals: 18)
        let date = Date(), feed = TokenChartFeed(asset: asset, network: "bsc", date: Date())
        await feed.setFailures(primary: URLError(.timedOut))
        let service = MarketDataService(database: database, transport: feed, now: { date })
        let id = UUID()
        _ = try await OathDiagnostics.$operationID.withValue(id) { try await service.chart(for: asset) }
        for _ in 0..<100 {
            if await reports.events(for: id).contains(where: { $0.operation == "token_chart_fallback" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let events = await reports.events(for: id)
        XCTAssertTrue(events.contains { $0.operation == "market_load" && $0.error.domain == "NSURLErrorDomain" && $0.error.code == -1001 })
        XCTAssertTrue(events.contains { $0.operation == "token_chart_fallback" })
        XCTAssertTrue(events.allSatisfy { $0.operationID == id && $0.context["chain"] == "bnb" && $0.privacyFiltered })
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        for secret in [asset.id, asset.reference, TokenChartFixtures.pool, "before_timestamp", "https://"] {
            XCTAssertFalse(encoded.contains(secret))
        }
        _ = try await OathDiagnostics.$operationID.withValue(id) { try await service.chart(for: asset) }
        try await Task.sleep(for: .milliseconds(50))
        let cachedEvents = await reports.events(for: id)
        XCTAssertEqual(cachedEvents.count, events.count)
    }
}
