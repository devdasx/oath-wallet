import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor MarketQueueReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

private actor HeldMarketResponse {
    var count = 0
    private var continuation: CheckedContinuation<PublicMarketRequests.Response, Never>?
    func response() async -> PublicMarketRequests.Response {
        count += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func finish(status: Int = 200) {
        continuation?.resume(returning: .init(data: Data("fixture".utf8), status: status))
        continuation = nil
    }
}

private struct PooledNativeMarketTransport: AnkrTransport {
    let pool: PublicMarketRequests
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let response = try await pool.send(request) {
            guard request.url?.host == "api.coinbase.com",
                  let pair = request.url?.path.split(separator: "/").dropLast().last else {
                XCTFail("A cooled-down provider was contacted")
                return .init(data: Data(), status: 500)
            }
            let code = pair.split(separator: "-")[0]
            return .init(data: Data("{\"data\":{\"base\":\"\(code)\",\"currency\":\"USD\",\"amount\":\"12\"}}".utf8), status: 200)
        }
        return (response.data, response.status)
    }
}

final class PublicMarketQueueRegressionTests: XCTestCase, @unchecked Sendable {
    private func request(_ coin: String) -> URLRequest {
        URLRequest(url: URL(string: "https://api.coingecko.com/api/v3/simple/price?ids=" + coin)!)
    }

    func testCancellationReturnsBeforeOtherConsumersSharedResponse() async throws {
        let pool = PublicMarketRequests(spacing: .zero), held = HeldMarketResponse()
        let request = request("ethereum")
        let first = Task { try await pool.send(request) { await held.response() } }
        while await held.count == 0 { await Task.yield() }
        let cancelled = expectation(description: "Cancelled consumer finishes while the other read is held")
        let second = Task {
            do { _ = try await pool.send(request) { await held.response() }; XCTFail("Cancelled read succeeded") }
            catch { XCTAssertTrue(error is CancellationError) }
            cancelled.fulfill()
        }
        // Allow the second actor call to join the held read; the producer cannot
        // finish until explicitly released, so cancellation must be independent.
        try await Task.sleep(for: .milliseconds(20))
        second.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        await held.finish()
        let result = try await first.value
        await second.value
        XCTAssertEqual(result.status, 200)
        let count = await held.count
        XCTAssertEqual(count, 1, "Cancelling one consumer must preserve shared work")
        _ = try await pool.send(request) { XCTFail("Successful shared result was not cached"); return .init(data: Data(), status: 500) }
    }

    func testQueuedCooldownIsNotAnotherProviderFailureAndRealFailuresRemainReported() async throws {
        let reports = MarketQueueReports()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: file) }
        OathDiagnostics.configure(file: file, transport: reports)
        let pool = PublicMarketRequests(spacing: .zero), held = HeldMarketResponse()
        let firstRequest = request("ethereum"), secondRequest = request("bitcoin")
        let first = Task {
            try await pool.send(firstRequest) {
                let response = await held.response()
                DiagnosticHTTP.response(response.data, status: response.status, request: firstRequest)
                return response
            }
        }
        while await held.count == 0 { await Task.yield() }
        let second = Task {
            try await pool.send(secondRequest) { XCTFail("Local cooldown issued another request"); return .init(data: Data(), status: 200) }
        }
        try await Task.sleep(for: .milliseconds(20))
        await held.finish(status: 429)
        let limited = try await first.value
        XCTAssertEqual(limited.status, 429)
        do { _ = try await second.value; XCTFail("Ignored shared cooldown") }
        catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }

        // Exercise the production consumers too: a coordinator-only check
        // misses repeated reports made by callers after a local deferral.
        let transport = PooledNativeMarketTransport(pool: pool)
        for _ in 0..<2 {
            let hype = try await HyperEVMMarkets(transport: transport).nativePrice()
            let mon = try await IndexedEVMMarkets(chain: .monad, transport: transport).nativePrice()
            let eth = try await IndexedEVMMarkets(chain: .unichain, transport: transport).nativePrice()
            XCTAssertEqual([hype.usd, mon.usd, eth.usd], ["12", "12", "12"])
        }

        // Availability failures retain their caller-visible errors but are
        // excluded from telemetry under the user's shared reporting policy.
        let failedRequest = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/BTC-USD/spot")!)
        do { _ = try await pool.send(failedRequest) { throw URLError(.timedOut) }; XCTFail() }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let invalidRequest = URLRequest(url: URL(string: "https://coins.llama.fi/prices/current/coingecko:bitcoin")!)
        do { _ = try await pool.send(invalidRequest) { throw AnkrError.invalidResponse }; XCTFail() }
        catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
        for _ in 0..<100 {
            if await reports.events.contains(where: { $0.error.message == "invalidResponse" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        // Let all already-admitted diagnostic events finish their asynchronous upload.
        try await Task.sleep(for: .milliseconds(100))
        let events = await reports.events
        XCTAssertEqual(events.filter { $0.context["http_status"] == "429" }.count, 0)
        XCTAssertEqual(events.filter { $0.operation == "public_market_request" && $0.error.domain == NSURLErrorDomain }.count, 0)
        XCTAssertEqual(events.filter { $0.operation == "public_market_request" && $0.error.message == "invalidResponse" }.count, 1)
        XCTAssertFalse(events.contains { $0.operation == "public_market_request" && $0.error.message == "http(429)" },
                       "A locally deferred request is not a new remote failure")
        XCTAssertFalse(events.contains { ["market_read", "native_price_fallback"].contains($0.operation) },
                       "Provider cooldown must not become a new failure in each chain consumer")
        let encoded = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(encoded.contains("?ids="))
        let count = await held.count
        XCTAssertEqual(count, 1)
    }

    func testCancelledFlightsLateCompletionCannotReplaceNewConsumerOrCache() async throws {
        let pool = PublicMarketRequests(spacing: .zero), held = HeldMarketResponse()
        let request = request("ethereum")
        let original = Task { try await pool.send(request) { await held.response() } }
        while await held.count == 0 { await Task.yield() }
        original.cancel()
        do { _ = try await original.value; XCTFail() }
        catch { XCTAssertTrue(error is CancellationError) }
        let replacement = Task {
            try await pool.send(request) { .init(data: Data("replacement".utf8), status: 200) }
        }
        // A transport may finish despite cancellation. Its old flight ID must
        // not resume/remove the replacement or populate the cache with old data.
        await held.finish()
        let fresh = try await replacement.value
        XCTAssertEqual(fresh.data, Data("replacement".utf8))
        let cached = try await pool.send(request) { XCTFail("Replacement was not cached"); return .init(data: Data(), status: 500) }
        XCTAssertEqual(cached.data, fresh.data)
    }
}
