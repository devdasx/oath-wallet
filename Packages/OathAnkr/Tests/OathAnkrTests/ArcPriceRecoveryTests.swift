import Foundation
import XCTest
@testable import OathAnkr

private actor ArcPriceRecoveryTransport: AnkrTransport {
    let primaryStatus: Int
    let primary: Data
    let fallback: Data
    let cancellation: Bool
    private(set) var requests: [URLRequest] = []

    init(status: Int = 404, primary: String = "{}", fallback: String? = nil, cancellation: Bool = false) {
        primaryStatus = status
        self.primary = Data(primary.utf8)
        self.fallback = Data((fallback ?? "{\"usd-coin\":{\"usd\":0.997,\"last_updated_at\":\(Int(Date().timeIntervalSince1970))}}").utf8)
        self.cancellation = cancellation
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        requests.append(request)
        if cancellation { throw CancellationError() }
        if request.url?.host == "api.coinbase.com" { return (primary, primaryStatus) }
        XCTAssertEqual(request.url?.host, "api.coingecko.com")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "ids" }?.value, "usd-coin")
        XCTAssertEqual(query.first { $0.name == "vs_currencies" }?.value, "usd")
        XCTAssertEqual(query.first { $0.name == "include_last_updated_at" }?.value, "true")
        return (fallback, 200)
    }
}

final class ArcPriceRecoveryTests: XCTestCase, @unchecked Sendable {
    func testMissingPrimaryQuoteUsesFreshUSDCQuoteWithoutAssumingPeg() async throws {
        let transport = ArcPriceRecoveryTransport()
        let price = try await ArcMarkets(transport: transport).nativePrice()
        XCTAssertEqual(price.reference, "native")
        XCTAssertEqual(price.usd, "0.997")
        XCTAssertEqual(price.source, "CoinGecko")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
    }
    func testValidPrimaryQuoteNeedsNoFallback() async throws {
        let transport = ArcPriceRecoveryTransport(status: 200, primary: "{\"data\":{\"base\":\"USDC\",\"currency\":\"USD\",\"amount\":\"0.998\"}}")
        let price = try await ArcMarkets(transport: transport).nativePrice()
        XCTAssertEqual(price.usd, "0.998")
        XCTAssertEqual(price.source, "Coinbase")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
    func testMalformedOrWrongIdentityPrimaryCannotBeMaskedByFallback() async throws {
        for body in ["{}", "{\"data\":{\"base\":\"USDT\",\"currency\":\"USD\",\"amount\":\"1\"}}"] {
            let transport = ArcPriceRecoveryTransport(status: 200, primary: body)
            do { _ = try await ArcMarkets(transport: transport).nativePrice(); XCTFail("Invalid primary must fail") }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }
    func testFallbackRejectsStaleFutureWrongCoinAndNonpositivePrices() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let bodies = [
            "{\"usd-coin\":{\"usd\":1,\"last_updated_at\":\(now - 7200)}}",
            "{\"usd-coin\":{\"usd\":1,\"last_updated_at\":\(now + 7200)}}",
            "{\"tether\":{\"usd\":1,\"last_updated_at\":\(now)}}",
            "{\"usd-coin\":{\"usd\":0,\"last_updated_at\":\(now)}}"
        ]
        for body in bodies {
            let transport = ArcPriceRecoveryTransport(fallback: body)
            do { _ = try await ArcMarkets(transport: transport).nativePrice(); XCTFail("Unverified quote must fail") }
            catch { XCTAssertEqual(error as? AnkrError, .invalidResponse) }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
        }
    }
    func testCancellationDoesNotStartFallback() async throws {
        let transport = ArcPriceRecoveryTransport(cancellation: true)
        do { _ = try await ArcMarkets(transport: transport).nativePrice(); XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }
}
