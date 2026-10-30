import Foundation
import XCTest
import OathDiagnostics
@testable import OathAnkr

private actor OutageCounter {
    private(set) var requests = 0
    func fail() async throws -> PublicMarketRequests.Response {
        requests += 1
        try await Task.sleep(for: .milliseconds(10))
        throw AnkrError.transport
    }
}

final class PublicMarketOutageTests: XCTestCase, @unchecked Sendable {
    private func request(_ symbol: String, host: String = "api.coinbase.com") -> URLRequest {
        URLRequest(url: URL(string: "https://\(host)/v2/prices/\(symbol)-USD/spot")!)
    }

    func testDifferentSymbolsShareOutageCooldownWithoutBlockingOtherHostsOrCachedQuotes() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = OutageCounter()
        let retained = try await pool.send(request("BTC")) { .init(data: Data("cached".utf8), status: 200) }
        let results = await withTaskGroup(of: Int.self) { group in
            for symbol in ["ETH", "SOL", "SUI", "APT", "TRX", "TON", "NEAR", "XLM", "XRP", "MON"] {
                let next = request(symbol)
                group.addTask {
                    do { _ = try await pool.send(next) { try await counter.fail() }; return 0 }
                    catch DiagnosticDeferral.publicMarketCooldown { return 1 }
                    catch AnkrError.transport { return 2 }
                    catch { return 3 }
                }
            }
            var results: [Int] = []
            for await value in group { results.append(value) }
            return results
        }
        let count = await counter.requests
        XCTAssertEqual(count, 1, "An outage must not be repeated for every asset")
        XCTAssertEqual(results.filter { $0 == 2 }.count, 1, "The original attempted failure remains observable")
        XCTAssertEqual(results.filter { $0 == 1 }.count, 9, "Only unattempted requests are deferred")
        let cached = try await pool.send(request("BTC")) { XCTFail("Fresh cached quote should remain usable"); return .init(data: Data(), status: 500) }
        XCTAssertEqual(cached.data, retained.data)
        let alternate = try await pool.send(request("ETH", host: "coins.llama.fi")) { .init(data: Data("alternate".utf8), status: 200) }
        XCTAssertEqual(alternate.status, 200)
    }

    func testDeferredNativeQuotesStillResolveThroughValidatedFallback() async throws {
        let pool = PublicMarketRequests(spacing: .zero), counter = OutageCounter()
        for code in ["ETH", "MON", "HYPE"] {
            let quote = try await NativePriceFallback.resolve(code) { url in
                let response = try await pool.send(URLRequest(url: url)) {
                    if url.host == "api.coinbase.com" { return try await counter.fail() }
                    XCTAssertEqual(url.host, "coins.llama.fi")
                    let key = String(url.lastPathComponent)
                    let data = try JSONSerialization.data(withJSONObject: ["coins": [key: [
                        "price": 1.25, "confidence": 0.99, "timestamp": Date().timeIntervalSince1970
                    ]]])
                    return .init(data: data, status: 200)
                }
                return response.data
            }
            XCTAssertEqual(quote.source, "DefiLlama")
            XCTAssertEqual(quote.usd, "1.25")
        }
        let attempted = await counter.requests
        XCTAssertEqual(attempted, 1, "Other native assets must use fallback during the shared outage")
    }

    func testTransientOutageExpiresAndAllowsRecovery() async throws {
        for failure: any Error in [URLError(.cannotFindHost), URLError(.timedOut), AnkrError.transport] {
            let pool = PublicMarketRequests(spacing: .zero, transportCooldown: .milliseconds(20))
            do { _ = try await pool.send(request("SOL")) { throw failure }; XCTFail() }
            catch { XCTAssertFalse(error is DiagnosticDeferral) }
            do { _ = try await pool.send(request("SUI")) { XCTFail("Cooldown bypassed"); return .init(data: Data(), status: 200) }; XCTFail() }
            catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketCooldown) }
            try await Task.sleep(for: .milliseconds(50))
            let value = try await pool.send(request("SUI")) { .init(data: Data("recovered".utf8), status: 200) }
            XCTAssertEqual(value.data, Data("recovered".utf8))
        }
    }

    func testCancellationAndMalformedResponsesDoNotCauseHostOutage() async throws {
        for failure: any Error in [CancellationError(), URLError(.cancelled), AnkrError.invalidResponse] {
            let pool = PublicMarketRequests(spacing: .zero)
            do { _ = try await pool.send(request("ETH")) { throw failure }; XCTFail() }
            catch { XCTAssertFalse(error is DiagnosticDeferral) }
            let value = try await pool.send(request("SOL")) { .init(data: Data(), status: 200) }
            XCTAssertEqual(value.status, 200)
        }
    }
}
