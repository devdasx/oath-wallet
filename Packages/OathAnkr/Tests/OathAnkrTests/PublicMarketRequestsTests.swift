import OathDiagnostics
import XCTest
@testable import OathAnkr

private actor MarketRequestCounter {
    var count = 0
    func response(status: Int = 200) async throws -> PublicMarketRequests.Response {
        count += 1
        try await Task.sleep(for: .milliseconds(20))
        return .init(data: Data("fixture".utf8), status: status, retryAfter: "120")
    }
}

private actor LivePublicMarketCacheTransport {
    var count = 0
    func response(_ request: URLRequest) async throws -> PublicMarketRequests.Response {
        count += 1
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              data.count <= 16 * 1024 * 1024 else { throw AnkrError.invalidResponse }
        return .init(data: data, status: response.statusCode)
    }
}
final class PublicMarketRequestsTests: XCTestCase, @unchecked Sendable {
    func testLivePublicCatalogAndQuoteSurviveInjectedSearchCachePressure() async throws {
        guard ProcessInfo.processInfo.environment["OATH_PUBLIC_MARKET_CACHE_LIVE"] == "1" else {
            throw XCTSkip("Opt-in anonymous catalog and quote reads; cache pressure is injected without more provider calls")
        }
        let pool = PublicMarketRequests(spacing: .zero), live = LivePublicMarketCacheTransport()
        let catalog = URLRequest(url: URL(string: "https://tokens.coingecko.com/base/all.json")!, timeoutInterval: 20)
        let native = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/ETH-USD/spot")!, timeoutInterval: 20)
        let list = try await pool.send(catalog) { try await live.response(catalog) }
        let quote = try await pool.send(native) { try await live.response(native) }
        let tokens = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: list.data)["tokens"].array)
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.allSatisfy { $0["chainId"].integer == 8453 })
        let price = try JSONDecoder().decode(SolanaJSON.self, from: quote.data)["data"]
        XCTAssertEqual(price["base"].string, "ETH"); XCTAssertEqual(price["currency"].string, "USD")
        XCTAssertNotNil(TonMarkets.positive(price["amount"]))
        for index in 0..<90 {
            let filler = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/cache-pressure-\(index)")!)
            // Synthetic entries exercise eviction without consuming 90 public
            // requests. Catalog and quote use the actual live provider bytes.
            _ = try await pool.send(filler) { .init(data: Data("fixture".utf8), status: 200) }
            let retainedList = try await pool.send(catalog) { try await live.response(catalog) }
            let retainedQuote = try await pool.send(native) { try await live.response(native) }
            XCTAssertEqual(retainedList.data, list.data); XCTAssertEqual(retainedQuote.data, quote.data)
        }
        let calls = await live.count
        XCTAssertEqual(calls, 2)
        print("LIVE MARKET CACHE: exact Base catalog and ETH/USD quote retained across 90 injected entries; provider requests=\(calls)")
    }

    func testBusySearchKeepsFrequentlyUsedCatalogAndQuotesWithoutRefetchingEverything() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let catalog = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!)
        let native = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd")!)
        _ = try await pool.send(catalog) { try await counter.response() }
        _ = try await pool.send(native) { try await counter.response() }
        for index in 0..<90 {
            let detail = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/fixture-\(index)")!)
            _ = try await pool.send(detail) { .init(data: Data("public metadata".utf8), status: 200) }
            // Home and search continue using the same public catalog and quote
            // while distinct token-detail responses fill the bounded cache.
            _ = try await pool.send(catalog) { try await counter.response() }
            _ = try await pool.send(native) { try await counter.response() }
        }
        let requests = await counter.count
        XCTAssertEqual(requests, 2, "Unrelated search results must not invalidate fresh catalog/quote responses")
        let limit = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/rate-limited")!)
        _ = try await pool.send(limit) { .init(data: Data(), status: 429) }
        let cached = try await pool.send(native) { try await counter.response() }
        XCTAssertEqual(cached.status, 200, "A provider cooldown must not hide a retained fresh quote")
        let final = await counter.count
        XCTAssertEqual(final, 2)
    }

    func testLargeResponseEvictsOnlyRequiredBytesAndKeepsHotQuote() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let native = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=monad&vs_currencies=usd")!)
        let older = URLRequest(url: URL(string: "https://tokens.coingecko.com/ethereum/all.json")!)
        let newer = URLRequest(url: URL(string: "https://tokens.coingecko.com/base/all.json")!)
        let incoming = URLRequest(url: URL(string: "https://tokens.coingecko.com/arbitrum-one/all.json")!)
        let large = Data(repeating: 0x20, count: 10 * 1024 * 1024)
        _ = try await pool.send(native) { try await counter.response() }
        _ = try await pool.send(older) { .init(data: large, status: 200) }
        _ = try await pool.send(newer) { .init(data: large, status: 200) }
        _ = try await pool.send(native) { try await counter.response() }
        _ = try await pool.send(incoming) { .init(data: large, status: 200) }
        let retained = try await pool.send(newer) { try await counter.response() }
        XCTAssertEqual(retained.data.count, large.count)
        _ = try await pool.send(native) { try await counter.response() }
        let before = await counter.count
        XCTAssertEqual(before, 1, "Memory pressure must keep unrelated fresh responses within the budget")
        _ = try await pool.send(older) { try await counter.response() }
        let after = await counter.count
        XCTAssertEqual(after, 2, "The oldest large response must actually be evicted to bound memory")
    }

    func testOKBChartSharesRequestsAndKrakenCooldownWithoutAdmittingPrivateRoutes() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let okb = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=OKBUSD&interval=60")!)
        XCTAssertTrue(PublicMarketRequests.accepts(okb))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await pool.send(okb) { try await counter.response() } } }
            try await group.waitForAll()
        }
        _ = try await pool.send(okb) { try await counter.response() }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        let blocked = PublicMarketRequests(spacing: .zero), other = MarketRequestCounter()
        let bitcoin = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=60")!)
        _ = try await blocked.send(bitcoin) { try await other.response(status: 429) }
        do { _ = try await blocked.send(okb) { try await other.response() }; XCTFail("OKB bypassed Kraken cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let total = await other.count
        XCTAssertEqual(total, 1)
        for value in ["https://api.kraken.com/0/private/Balance", okb.url!.absoluteString + "&key=fixture",
                      okb.url!.absoluteString + "#extra", okb.url!.absoluteString.replacingOccurrences(of: "OKBUSD", with: "OKBUSDT")] {
            XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: value)!)))
        }
        var authenticated = okb
        authenticated.setValue("fixture", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
    }
    func testTRXChartSharesRequestsAndKrakenCooldownWithoutAdmittingPrivateRoutes() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let trx = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=TRXUSD&interval=60")!)
        XCTAssertTrue(PublicMarketRequests.accepts(trx))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await pool.send(trx) { try await counter.response() } } }
            try await group.waitForAll()
        }
        _ = try await pool.send(trx) { try await counter.response() }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        let blocked = PublicMarketRequests(spacing: .zero), other = MarketRequestCounter()
        let bitcoin = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=60")!)
        _ = try await blocked.send(bitcoin) { try await other.response(status: 429) }
        do { _ = try await blocked.send(trx) { try await other.response() }; XCTFail("TRX bypassed Kraken cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let total = await other.count
        XCTAssertEqual(total, 1)
        for value in ["https://api.kraken.com/0/private/Balance", trx.url!.absoluteString + "&key=fixture",
                      trx.url!.absoluteString + "#extra", trx.url!.absoluteString.replacingOccurrences(of: "TRXUSD", with: "TRXUSDT")] {
            XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: value)!)))
        }
        var authenticated = trx
        authenticated.setValue("fixture", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
    }
    func testBitcoinChartCoalescesSeparatelyAndSharesKrakenQuota() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let bitcoin = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=60")!)
        let dogecoin = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=XDGUSD&interval=60")!)
        XCTAssertTrue(PublicMarketRequests.accepts(bitcoin))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await pool.send(bitcoin) { try await counter.response() } } }
            try await group.waitForAll()
        }
        _ = try await pool.send(bitcoin) { try await counter.response() }
        _ = try await pool.send(dogecoin) { try await counter.response(status: 429) }
        let count = await counter.count
        XCTAssertEqual(count, 2, "Coins must not share a cached response")
        let blocked = PublicMarketRequests(spacing: .zero), other = MarketRequestCounter()
        _ = try await blocked.send(dogecoin) { try await other.response(status: 429) }
        do { _ = try await blocked.send(bitcoin) { try await other.response() }; XCTFail("Bypassed host cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let blockedCount = await other.count
        XCTAssertEqual(blockedCount, 1)
        for suffix in ["&key=fixture", "#fragment", "&since=1"] {
            XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: bitcoin.url!.absoluteString + suffix)!)))
        }
        var authenticated = bitcoin
        authenticated.setValue("fixture", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
    }
    func testDogecoinChartCoalescesOnlyItsAnonymousMarketRoute() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let chart = URLRequest(url: URL(string: "https://api.kraken.com/0/public/OHLC?pair=XDGUSD&interval=60")!)
        XCTAssertTrue(PublicMarketRequests.accepts(chart))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await pool.send(chart) { try await counter.response() } } }
            try await group.waitForAll()
        }
        _ = try await pool.send(chart) { try await counter.response() }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        for value in ["https://api.kraken.com/0/private/Balance", chart.url!.absoluteString + "&key=fixture",
                      chart.url!.absoluteString + "#fragment"] {
            XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: value)!)))
        }
        var authenticated = chart
        authenticated.setValue("fixture", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
    }
    func testNativeInformationSharesRequestsAndProviderQuota() async throws {
        for identity in ["doge-dogecoin", "btc-bitcoin", "bch-bitcoin-cash", "sui-sui", "apt-aptos", "okb-okb"] {
            let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
            let coin = URLRequest(url: URL(string: "https://api.coinpaprika.com/v1/coins/" + identity)!)
            XCTAssertTrue(PublicMarketRequests.accepts(coin))
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<20 { group.addTask { _ = try await pool.send(coin) { try await counter.response() } } }
                try await group.waitForAll()
            }
            _ = try await pool.send(coin) { try await counter.response() }
            let count = await counter.count
            XCTAssertEqual(count, 1)
            let ticker = URLRequest(url: URL(string: "https://api.coinpaprika.com/v1/tickers/" + identity)!)
            _ = try await pool.send(ticker) { try await counter.response(status: 429) }
            let rune = URLRequest(url: URL(string: "https://api.coinpaprika.com/v1/tickers/rune-thorchain")!)
            do { _ = try await pool.send(rune) { try await counter.response() }; XCTFail("Cross-coin quota bypass") }
            catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
            let total = await counter.count
            XCTAssertEqual(total, 2)
            for extra in ["?key=fixture", "#extra"] {
                XCTAssertFalse(PublicMarketRequests.accepts(URLRequest(url: URL(string: coin.url!.absoluteString + extra)!)))
            }
            var authenticated = coin
            authenticated.setValue("fixture", forHTTPHeaderField: "Authorization")
            XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
        }
    }
    func testTokenListRequestsShareCacheAndHostCooldownAcrossChains() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let story = URLRequest(url: URL(string: "https://tokens.coingecko.com/story/all.json")!)
        XCTAssertTrue(PublicMarketRequests.accepts(story))
        async let first = pool.send(story) { try await counter.response() }
        async let second = pool.send(story) { try await counter.response() }
        _ = try await (first, second)
        _ = try await pool.send(story) { try await counter.response() }
        let count = await counter.count; XCTAssertEqual(count, 1)
        let telos = URLRequest(url: URL(string: "https://tokens.coingecko.com/telos/all.json")!)
        _ = try await pool.send(telos) { try await counter.response(status: 429) }
        let xlayer = URLRequest(url: URL(string: "https://tokens.coingecko.com/x-layer/all.json")!)
        do { _ = try await pool.send(xlayer) { try await counter.response() }; XCTFail("Ignored token-list host cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let finalCount = await counter.count; XCTAssertEqual(finalCount, 2)
        var authenticated = story
        authenticated.setValue("fixture", forHTTPHeaderField: "Authorization")
        XCTAssertFalse(PublicMarketRequests.accepts(authenticated))
    }
    func testConcurrentChainCatalogsCoalesceAndReuseSuccessfulResponse() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let request = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/list?include_platform=true")!)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { _ = try await pool.send(request) { try await counter.response() } } }
            try await group.waitForAll()
        }
        _ = try await pool.send(request) { try await counter.response() }
        let count = await counter.count; XCTAssertEqual(count, 1)
    }
    func testRateLimitBlocksDifferentCoinAndQueuedCallsWithoutAnotherRequest() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let first = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=ethereum")!)
        let second = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=monad")!)
        let reply = try await pool.send(first) { try await counter.response(status: 429) }
        XCTAssertEqual(reply.status, 429)
        do { _ = try await pool.send(second) { try await counter.response() }; XCTFail("Ignored host cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
        let count = await counter.count; XCTAssertEqual(count, 1)
    }
    func testContractProvidersShareBudgetAndRejectAuthenticatedCaching() async throws {
        for host in ["api.geckoterminal.com", "api.dexscreener.com", "coins.llama.fi"] {
            let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
            var request = URLRequest(url: URL(string: "https://" + host + "/public")!)
            XCTAssertTrue(PublicMarketRequests.accepts(request))
            let publicRequest = request
            async let first = pool.send(publicRequest) { try await counter.response() }
            async let second = pool.send(publicRequest) { try await counter.response() }
            _ = try await (first, second)
            let count = await counter.count; XCTAssertEqual(count,1)
            request.setValue("fixture",forHTTPHeaderField:"Authorization")
            XCTAssertFalse(PublicMarketRequests.accepts(request))
        }
    }
    func testAbandonedProviderRacesReleaseQueueCapacity() async throws {
        let pool = PublicMarketRequests(spacing: .zero)
        // More races than the queue limit. Every abandoned caller must release
        // its underlying task promptly, without waiting for its timeout.
        for index in 0..<40 {
            let request = URLRequest(url: URL(string:"https://api.geckoterminal.com/token/\(index)")!)
            let task = Task {
                try await pool.send(request) {
                    try await Task.sleep(for:.seconds(20))
                    return .init(data:Data(),status:200)
                }
            }
            try await Task.sleep(for:.milliseconds(2))
            task.cancel()
            do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        }
        let request = URLRequest(url:URL(string:"https://api.geckoterminal.com/token/final")!)
        let result = try await pool.send(request) { .init(data:Data("ok".utf8),status:200) }
        XCTAssertEqual(result.status,200)
    }
    func testRPCAndAuthenticatedRequestsNeverEnterCache() {
        var request = URLRequest(url: URL(string: "https://rpc.ankr.com/monad/key")!)
        XCTAssertFalse(PublicMarketRequests.accepts(request))
        request.url = URL(string: "https://api.coingecko.com/api/v3/coins/list")!
        XCTAssertTrue(PublicMarketRequests.accepts(request))
        request.setValue("secret", forHTTPHeaderField: "x-cg-demo-api-key")
        XCTAssertFalse(PublicMarketRequests.accepts(request))
        request.allHTTPHeaderFields = [:]; request.httpMethod = "POST"
        XCTAssertFalse(PublicMarketRequests.accepts(request))
    }
    func testRetryAfterIsBoundedAndSupportsHTTPDate() {
        XCTAssertEqual(PublicMarketRequests.retryDelay("NaN"), 60)
        XCTAssertEqual(PublicMarketRequests.retryDelay("999999"), 3600)
        XCTAssertEqual(PublicMarketRequests.retryDelay("-1"), 60)
        XCTAssertEqual(PublicMarketRequests.retryDelay("Thu, 01 Jan 1970 00:02:00 GMT", now: Date(timeIntervalSince1970: 0)), 120)
    }
    func testCancelledConsumerCannotCancelOtherChainsSharedRead() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = MarketRequestCounter()
        let request = URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/coins/list")!)
        let first = Task { try await pool.send(request) { try await counter.response() } }
        let second = Task { try await pool.send(request) { try await counter.response() } }
        try await Task.sleep(for: .milliseconds(5)); first.cancel()
        let result = try await second.value
        XCTAssertEqual(result.status, 200)
        do { _ = try await first.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let count = await counter.count; XCTAssertEqual(count, 1)
    }
}
