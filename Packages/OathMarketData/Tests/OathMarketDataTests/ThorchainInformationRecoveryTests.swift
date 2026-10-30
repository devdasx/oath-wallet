import XCTest
import OathDatabase
@testable import OathMarketData

actor RuneInformationTransport: MarketTransport {
    let primaryError: any Error
    var requests: [URL] = []
    var coin: Data
    var ticker: Data
    init(now: Date, primaryError: any Error = MarketDataError.rateLimited) {
        self.primaryError = primaryError
        coin = Data(#"{"id":"rune-thorchain","name":"THORChain","symbol":"RUNE","is_active":true,"description":"A <b>liquidity</b> network.","logo":"https://static.coinpaprika.com/coin/rune-thorchain/logo.png","links":{"website":["https://thorchain.org"]}}"#.utf8)
        ticker = Data("""
        {"id":"rune-thorchain","name":"THORChain","symbol":"RUNE","last_updated":"\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)))","total_supply":415000571,"circulating_supply":null,"quotes":{"USD":{"market_cap":217810156}}}
        """.utf8)
    }
    func data(from url: URL) async throws -> Data {
        requests.append(url)
        if url.host == "api.coingecko.com" { throw primaryError }
        guard url.host == "api.coinpaprika.com" else { throw MarketDataError.invalidResponse }
        switch url.path {
        case "/v1/coins/rune-thorchain": return coin
        case "/v1/tickers/rune-thorchain": return ticker
        default: throw MarketDataError.invalidResponse
        }
    }
    func replace(coin: Data? = nil, ticker: Data? = nil) {
        if let coin { self.coin = coin }
        if let ticker { self.ticker = ticker }
    }
}

private actor LiveRuneInformation: MarketTransport {
    let live = URLSessionMarketTransport()
    var responses: [String: Data] = [:]
    func data(from url: URL) async throws -> Data {
        if url.host == "api.coingecko.com" { throw MarketDataError.rateLimited }
        guard NativeInformation.accepts(url) else { throw MarketDataError.invalidResponse }
        let data = try await live.data(from: url)
        responses[url.path] = data
        return data
    }
}

@MainActor final class ThorchainInformationRecoveryTests: XCTestCase {
    private let rune = MarketAsset(id: "thorchain:native", networkID: "thorchain", reference: "native", decimals: 8)

    func testRateLimitedInformationRecoversWithVerifiedMetadataAndOriginalTimestamp() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), now = Date(timeIntervalSince1970: 1_792_222_000)
        let db = try await OathDatabase.open(at: path), transport = RuneInformationTransport(now: now)
        let service = MarketDataService(database: db, transport: transport, now: { now })
        let result = try await service.information(for: rune)
        XCTAssertEqual(result.value.name, "THORChain")
        XCTAssertEqual(result.value.symbol, "RUNE")
        XCTAssertEqual(result.value.description, "A liquidity network.")
        XCTAssertEqual(result.value.website, "https://thorchain.org")
        XCTAssertEqual(result.value.providerURL, "https://coinpaprika.com/coin/rune-thorchain/")
        XCTAssertEqual(result.value.marketCaps?["usd"], 217810156)
        XCTAssertEqual(result.value.totalSupply, 415000571)
        XCTAssertNil(result.value.circulatingSupply)
        XCTAssertEqual(result.fetchedAt, now.addingTimeInterval(-60))
        let again = try await service.information(for: rune)
        XCTAssertEqual(again.value, result.value)
        XCTAssertEqual(again.fetchedAt, result.fetchedAt)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        let reopened = try await OathDatabase.open(at: path)
        let saved = try await MarketDataService(database: reopened).cachedInformation(for: rune)
        XCTAssertEqual(saved?.value, result.value)
        XCTAssertEqual(saved?.fetchedAt, result.fetchedAt)
    }

    func testRecoveryCoalescesConcurrentScreensAndRetainsNewerCanonicalData() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_792_222_000), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let transport = RuneInformationTransport(now: now), service = MarketDataService(database: db, transport: transport, now: { now })
        let asset = rune
        let results = try await withThrowingTaskGroup(of: CachedMarketValue<AssetInformation>.self) { group in
            for _ in 0..<12 { group.addTask { try await service.information(for: asset) } }
            var results: [CachedMarketValue<AssetInformation>] = []
            for try await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 12)
        XCTAssertTrue(results.allSatisfy { $0.value == results[0].value && $0.fetchedAt == results[0].fetchedAt })
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        let newer = AssetInformation(providerID: "thorchain", name: "THORChain", symbol: "RUNE", description: "Newer verified data", imageURL: nil, website: nil, providerURL: "https://www.coingecko.com/en/coins/thorchain")
        try await db.saveMarketCache(.init(key: "v2.info.native.thorchain", source: "CoinGecko", payload: JSONEncoder().encode(newer), fetchedAt: now.timeIntervalSince1970))
        let value = try await service.information(for: rune, force: true)
        XCTAssertEqual(value.value, newer)
        XCTAssertEqual(value.fetchedAt, now)
    }

    func testFallbackNeverAppliesToOtherAssetsOrInvalidPrimaryOrCancellation() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let cases: [(MarketAsset, any Error)] = [
            (rune, MarketDataError.invalidResponse), (rune, URLError(.cancelled)), (rune, CancellationError()),
            (.init(id: "invalid", networkID: "thorchain", reference: "native", decimals: 18), MarketDataError.rateLimited),
            (.init(id: "tron:native", networkID: "tron", reference: "native", decimals: 6), MarketDataError.rateLimited),
            (.init(id: "thorchain:tcy", networkID: "thorchain", reference: "tcy", decimals: 8), MarketDataError.rateLimited)
        ]
        for (asset, failure) in cases {
            let transport = RuneInformationTransport(now: Date(), primaryError: failure)
            do { _ = try await MarketDataService(database: db, transport: transport).information(for: asset); XCTFail("Unexpected recovery") }
            catch { if failure is CancellationError || (failure as? URLError)?.code == .cancelled { XCTAssertTrue(error is CancellationError) } }
            let requests = await transport.requests
            XCTAssertFalse(requests.contains { $0.host == "api.coinpaprika.com" })
        }
    }

    func testRejectsWrongIdentityStaleFutureAndMalformedStatsWithoutOverwritingCache() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_792_222_000), db = try await OathDatabase.open(at: folder.appendingPathComponent("test.sqlite"))
        let good = RuneInformationTransport(now: now)
        let coin = await good.coin, ticker = await good.ticker
        let saved = try await MarketDataService(database: db, transport: good, now: { now }).information(for: rune)
        let coinText = String(decoding: coin, as: UTF8.self), tickerText = String(decoding: ticker, as: UTF8.self)
        let date = ISO8601DateFormatter()
        let invalid: [(String, String)] = [
            (coinText.replacingOccurrences(of: "rune-thorchain", with: "rune-impostor"), tickerText),
            (coinText, tickerText.replacingOccurrences(of: "rune-thorchain", with: "btc-bitcoin")),
            (coinText.replacingOccurrences(of: "RUNE", with: "OTHER"), tickerText),
            (coinText.replacingOccurrences(of: "THORChain", with: "Other"), tickerText),
            (coinText.replacingOccurrences(of: "true", with: "false"), tickerText),
            (coinText, tickerText.replacingOccurrences(of: date.string(from: now.addingTimeInterval(-60)), with: date.string(from: now.addingTimeInterval(-901)))),
            (coinText, tickerText.replacingOccurrences(of: date.string(from: now.addingTimeInterval(-60)), with: date.string(from: now.addingTimeInterval(61)))),
            (coinText, tickerText.replacingOccurrences(of: "217810156", with: "-1")),
            (coinText, tickerText.replacingOccurrences(of: "415000571", with: "true")),
            (coinText, tickerText.replacingOccurrences(of: "415000571", with: "\"not a number\"")),
            (coinText, tickerText.replacingOccurrences(of: "415000571", with: "1e999")),
            ("{}", tickerText), (coinText, "{}")
        ]
        for (badCoin, badTicker) in invalid {
            let transport = RuneInformationTransport(now: now)
            await transport.replace(coin: Data(badCoin.utf8), ticker: Data(badTicker.utf8))
            let service = MarketDataService(database: db, transport: transport, now: { now })
            do { _ = try await service.information(for: rune, force: true); XCTFail("Invalid fallback accepted") }
            catch { }
            let retained = try await service.cachedInformation(for: rune)
            XCTAssertEqual(retained?.value, saved.value)
            XCTAssertEqual(retained?.fetchedAt, saved.fetchedAt)
        }
    }

    func testDocumentedMissingStatisticsStayAbsentAndLinksAreFiltered() async throws {
        let now = Date(timeIntervalSince1970: 1_792_222_000), transport = RuneInformationTransport(now: now)
        let coin = await transport.coin, ticker = await transport.ticker
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: coin) as? [String: Any])
        object["logo"] = "https://attacker.example/logo.png"
        object["links"] = ["website": ["javascript:alert(1)", "https://user:pass@example.com", "https://thorchain.org"]]
        for absent in ["null", "\"\""] {
            let changed = Data(String(decoding: ticker, as: UTF8.self).replacingOccurrences(of: "415000571", with: absent).replacingOccurrences(of: "217810156", with: absent).utf8)
            let result = try NativeInformation.decode(coin: JSONSerialization.data(withJSONObject: object), ticker: changed, for: rune, at: now)
            XCTAssertNil(result.value.marketCaps)
            XCTAssertNil(result.value.totalSupply)
            XCTAssertNil(result.value.circulatingSupply)
            XCTAssertNil(result.value.imageURL)
            XCTAssertEqual(result.value.website, "https://thorchain.org")
        }
    }

    func testLiveRecoveryUsesProductionTransportAndActualProviderTimestamp() async throws {
        guard ProcessInfo.processInfo.environment["OATH_RUNE_INFO_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public metadata/ticker read with injected CoinGecko rate limit")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("test.sqlite"), db = try await OathDatabase.open(at: path)
        let transport = LiveRuneInformation(), service = MarketDataService(database: db, transport: transport)
        let result = try await service.information(for: rune)
        XCTAssertEqual(result.value.providerID, "coinpaprika:rune-thorchain")
        XCTAssertEqual(result.value.symbol, "RUNE")
        XCTAssertFalse(result.value.description.isEmpty)
        XCTAssertGreaterThan(try XCTUnwrap(result.value.marketCaps?["usd"]), 0)
        let responses = await transport.responses
        XCTAssertEqual(responses.count, 2)
        let ticker = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(responses["/v1/tickers/rune-thorchain"])) as? [String: Any])
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: XCTUnwrap(ticker["last_updated"] as? String)))
        XCTAssertEqual(result.fetchedAt, date)
        let reopened = try await OathDatabase.open(at: path)
        let cached = try await MarketDataService(database: reopened).cachedInformation(for: rune)
        XCTAssertEqual(cached?.value, result.value)
        XCTAssertEqual(cached?.fetchedAt, date)
        print("RUNE_INFO_LIVE: exact public identity, metadata, market statistics and provider timestamp; persisted and reopened")
    }
}
