import XCTest
@testable import OathDiagnostics

final class MarketAbsenceTests: XCTestCase {
    private func request(_ host: String, _ path: String) -> URLRequest {
        URLRequest(url: URL(string: "https://" + host + path)!)
    }

    func testOnlyExactReadOnlyMissingListingEnvelopesAreExcluded() {
        let cases: [(String, String, String)] = [
            ("api.geckoterminal.com", "/api/v2/networks/eth/tokens/0xabc", #"{"errors":[{"status":"404","title":"Not Found"}],"meta":{"ref_id":"01c4c025-1625-491d-928b-4078a07fd9cd"}}"#),
            ("api.exchange.coinbase.com", "/products/SNT-USD/candles", #"{"message":"NotFound"}"#),
            ("api.exchange.coinbase.com", "/products/SNT-USD/stats", #"{"message":"NotFound"}"#),
            ("api.coinbase.com", "/v2/prices/XDAI-USD/spot", #"{"error":"rpc error: code = NotFound desc = not found","code":5,"message":"rpc error: code = NotFound desc = not found"}"#),
            ("api.coingecko.com", "/api/v3/coins/missing-coin", #"{"error":"Could not find coin with the given id"}"#),
            ("api.coingecko.com", "/api/v3/coins/missing-coin/market_chart", #"{"error":"coin not found"}"#),
            ("api.coingecko.com", "/api/v3/coins/ethereum/contract/0xabc", #"{"error":"coin not found"}"#),
            ("api.coingecko.com", "/api/v3/coins/ethereum/contract/0xabc/market_chart", #"{"error":"coin not found"}"#)
        ]
        for (host, path, body) in cases {
            let bytes = Data(body.utf8)
            var r = request(host, path)
            XCTAssertTrue(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: r), path)
            for status in [200, 400, 401, 403, 429, 500, 503] {
                XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: status, request: r))
            }
            r.httpMethod = "POST"
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: r))
            r.httpMethod = "GET"; r.httpBody = Data("{}".utf8)
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: r))
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(bytes, status: 404, request: request("untrusted.example", path)))
        }
    }

    func testCatalogFailuresProxyErrorsAndMalformedBodiesAreNotExcluded() {
        for (host, paths, body) in [
            ("api.geckoterminal.com", ["/api/v2/networks", "/api/v2/networks/eth/pools/0xabc", "/api/v2/networks/eth/tokens"], #"{"errors":[{"status":"404","title":"Not Found"}],"meta":{"ref_id":"01c4c025-1625-491d-928b-4078a07fd9cd"}}"#),
            ("api.exchange.coinbase.com", ["/currencies", "/products", "/products/SNT-EUR/candles", "/products/SNT-USD/orders"], #"{"message":"NotFound"}"#),
            ("api.coingecko.com", ["/api/v3/coins/list", "/api/v3/coins/markets", "/api/v3/coins/ethereum/tickers", "/other/ethereum"], #"{"error":"coin not found"}"#)
        ] {
            for path in paths {
                XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(Data(body.utf8), status: 404, request: request(host, path)))
            }
        }
        let r = request("api.coingecko.com", "/api/v3/coins/ethereum/contract/0xabc")
        for body in ["", "<html>not found</html>", "{}", #"{"error":"upstream unavailable"}"#,
                     #"{"error":"coin not found","extra":"unexpected"}"#, String(repeating: "x", count: 16_385)] {
            XCTAssertFalse(DiagnosticHTTP.expectedMarketDataAbsence(Data(body.utf8), status: 404, request: r))
        }
    }
}
