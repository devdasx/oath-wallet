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
final class PublicMarketRequestsTests: XCTestCase, @unchecked Sendable {
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
        catch { XCTAssertEqual(error as? AnkrError, .http(429)) }
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
