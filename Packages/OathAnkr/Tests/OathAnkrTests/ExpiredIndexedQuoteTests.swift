import XCTest
import OathDiagnostics
@testable import OathAnkr

final class ExpiredIndexedQuoteTests: XCTestCase, @unchecked Sendable {
    func testIoTeXUsesFreshExplorerQuoteAndNeverReturnsExpiredPrice() async throws {
        let quote = try await IndexedEVMMarkets(chain: .iotex, transport: ExpiredIoTeXQuoteTransport(expiredExplorer: false)).nativePrice()
        XCTAssertEqual(quote.usd, "0.0036")
        XCTAssertEqual(quote.source, "IoTeXScan")
        do {
            _ = try await IndexedEVMMarkets(chain: .iotex, transport: ExpiredIoTeXQuoteTransport(expiredExplorer: true)).nativePrice()
            XCTFail("No fresh provider quote must remain unavailable")
        } catch { XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketQuoteUnavailable) }
    }
    func testOnlyWellFormedExpiredQuotesAreAvailabilityOutcomes() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        for source in ["llama", "iotexscan"] {
            func decode(time: Double, price: String = "0.0036", confidence: Double = 0.99, status: String = "1") throws {
                if source == "llama" {
                    let json: SolanaJSON = .object(["coins": .object(["coingecko:iotex": .object([
                        "price": .string(price), "timestamp": .number(String(time)), "confidence": .number(String(confidence))])])])
                    _ = try NativePriceFallback.decodeLlama(json, key: "coingecko:iotex", now: now)
                } else {
                    let data = try JSONSerialization.data(withJSONObject: ["status": status, "result": ["ethusd": price, "ethusd_timestamp": time]])
                    _ = try IndexedEVMMarkets.decodeIoTeXNativePrice(data, now: now)
                }
            }
            try decode(time: 1_100) // The existing 15-minute boundary stays valid.
            XCTAssertThrowsError(try decode(time: 1_099)) { error in
                XCTAssertEqual(error as? DiagnosticDeferral, .publicMarketQuoteUnavailable)
                XCTAssertTrue(VerifiedEVMTokenCatalog.isUnavailable(error))
            }
            for time in [0.0, -1, 2_061] {
                XCTAssertThrowsError(try decode(time: time)) { error in
                    XCTAssertEqual(error as? AnkrError, .invalidResponse)
                }
            }
            XCTAssertThrowsError(try decode(time: 1_099, price: "-1")) { error in
                XCTAssertEqual(error as? AnkrError, .invalidResponse)
            }
            if source == "llama" {
                XCTAssertThrowsError(try decode(time: 1_099, confidence: 0.5)) { error in
                    XCTAssertEqual(error as? AnkrError, .invalidResponse)
                }
            } else {
                XCTAssertThrowsError(try decode(time: 1_099, status: "0")) { error in
                    XCTAssertEqual(error as? AnkrError, .invalidResponse)
                }
            }
        }
    }
}

private struct ExpiredIoTeXQuoteTransport: AnkrTransport {
    let expiredExplorer: Bool
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body: [String: Any]
        switch request.url?.host {
        case "coins.llama.fi":
            body = ["coins": ["coingecko:iotex": ["price": "99", "confidence": 0.99, "timestamp": Date().timeIntervalSince1970 - 1_800]]]
        case "api.coingecko.com": return (Data(), 429)
        case "dev.iotexscan.io":
            body = ["status": "1", "result": ["ethusd": "0.0036", "ethusd_timestamp": Date().timeIntervalSince1970 - (expiredExplorer ? 1_800 : 0)]]
        default: XCTFail("Unexpected price provider"); throw AnkrError.invalidResponse
        }
        return (try JSONSerialization.data(withJSONObject: body), 200)
    }
}
