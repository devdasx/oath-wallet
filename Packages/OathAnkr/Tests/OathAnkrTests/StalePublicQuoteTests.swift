import Foundation
import OathDiagnostics
import XCTest
@testable import OathAnkr

private let staleQuote = Data(#"{"error":"rpc error: code = NotFound desc = rate found but was stale","code":5,"message":"rpc error: code = NotFound desc = rate found but was stale"}"#.utf8)

private actor StaleQuoteTransport: AnkrTransport {
    let pool = PublicMarketRequests(spacing: .zero)
    private(set) var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        hosts.append(request.url!.host!)
        let response = try await pool.send(request) {
            if request.url?.host == "api.coinbase.com" { return .init(data: staleQuote, status: 404) }
            if request.url?.host == "coins.llama.fi" {
                let key = request.url!.lastPathComponent
                let row: [String: Any] = ["price": "3.25", "confidence": 0.99, "timestamp": Date().timeIntervalSince1970, "symbol": "TON"]
                return .init(data: try JSONSerialization.data(withJSONObject: ["coins": [key: row]]), status: 200)
            }
            if request.url?.host == "api.coingecko.com" {
                // Exercise HyperEVM's secondary Coinbase route as well as
                // Arc's independent USDC fallback.
                if request.url!.query!.contains("hyperliquid") { return .init(data: Data(), status: 503) }
                let row: [String: Any] = ["usd": "0.997", "last_updated_at": Date().timeIntervalSince1970]
                return .init(data: try JSONSerialization.data(withJSONObject: ["usd-coin": row]), status: 200)
            }
            XCTAssertEqual(request.url?.path, "/tokens/v1/aptos/0xa")
            return .init(data: Data(#"[{"chainId":"aptos","baseToken":{"address":"0xa"},"priceUsd":"3.25","liquidity":{"usd":2000000}}]"#.utf8), status: 200)
        }
        return (response.data, response.status)
    }
}

final class StalePublicQuoteTests: XCTestCase, @unchecked Sendable {
    func testOtherAffectedNativeClientsKeepTheirValidatedFallbacks() async throws {
        for chain: IndexedEVMChain in [.monad, .celo] {
            let price = try await IndexedEVMMarkets(chain: chain, transport: StaleQuoteTransport()).nativePrice()
            XCTAssertEqual(price.usd, "3.25")
            XCTAssertEqual(price.reference, "native")
        }
        let ton = try await TonMarkets(transport: StaleQuoteTransport()).nativePrice()
        XCTAssertEqual(ton.usd, "3.25")
        let hype = try await HyperEVMMarkets(transport: StaleQuoteTransport()).nativePrice()
        XCTAssertEqual(hype.usd, "3.25")
        let arc = try await ArcMarkets(transport: StaleQuoteTransport()).nativePrice()
        XCTAssertEqual(arc.usd, "0.997")
    }
    func testAptosRecoversFromExactReportedStale404UsingVerifiedNativeContract() async throws {
        let transport = StaleQuoteTransport()
        let result = try await AptosMarkets(transport: transport).nativePrice()
        XCTAssertEqual(result.reference, "native")
        XCTAssertEqual(result.usd, "3.25")
        XCTAssertEqual(result.source, "DEX Screener")
        let hosts = await transport.hosts
        XCTAssertEqual(hosts, ["api.coinbase.com", "api.dexscreener.com"])
    }

    func testStaleQuoteIsNotCachedOrUsedAndDoesNotBlockAnotherSymbol() async throws {
        let pool = PublicMarketRequests(spacing: .zero)
        let request = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/MON-USD/spot")!)
        do {
            _ = try await pool.send(request) { .init(data: staleQuote, status: 404) }
            XCTFail("A stale quote must be an explicit unavailable outcome")
        } catch {
            XCTAssertTrue(error is DiagnosticDeferral)
            XCTAssertFalse(OathDiagnostics.isExpectedCancellation(error))
        }
        let other = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/ETH-USD/spot")!)
        let fresh = Data(#"{"data":{"base":"ETH","currency":"USD","amount":"3000"}}"#.utf8)
        let response = try await pool.send(other) { .init(data: fresh, status: 200) }
        XCTAssertEqual(response.data, fresh)
        let recovered = try await pool.send(request) { .init(data: Data("fresh".utf8), status: 200) }
        XCTAssertEqual(recovered.data, Data("fresh".utf8))
    }

    func testUnrelated404AndAuthenticatedRequestsRetainTheirResponse() async throws {
        for payload in [Data("<html>Not found</html>".utf8), Data(#"{"code":5,"message":"permission denied"}"#.utf8)] {
            let request = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/MON-USD/spot")!)
            let response = try await PublicMarketRequests(spacing: .zero).send(request) { .init(data: payload, status: 404) }
            XCTAssertEqual(response.status, 404)
            XCTAssertEqual(response.data, payload)
        }
        var request = URLRequest(url: URL(string: "https://api.coinbase.com/v2/prices/MON-USD/spot")!)
        request.setValue("fixture", forHTTPHeaderField: "Authorization")
        let response = try await PublicMarketRequests(spacing: .zero).send(request) { .init(data: staleQuote, status: 404) }
        XCTAssertEqual(response.status, 404)
    }
}
