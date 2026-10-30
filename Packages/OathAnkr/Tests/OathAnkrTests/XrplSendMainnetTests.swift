import XCTest
@testable import OathAnkr

/// Read-only mainnet verification: even an accidental broadcast call cannot
/// leave this transport. Uses public ledger fixtures, never application keys.
private actor XrplQuoteOnlyTransport: AnkrTransport {
    private let base = AnkrHTTPTransport()
    private(set) var methods = [String]()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(XrplJSON.self, from: request.httpBody ?? Data())
        guard let method = body["method"].string,
              ["server_info", "fee", "account_info", "simulate"].contains(method) else {
            throw XrplSendError.configuration
        }
        methods.append(method)
        return try await base.send(request)
    }
}

final class XrplSendMainnetTests: XCTestCase {
    func testLiveReadOnlyMainnetQuoteAndMaxWithConfiguredProviderAndFallback() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_XRPL_QUOTE_MAINNET_KEY"] else {
            throw XCTSkip("Explicit read-only mainnet quote opt-in required")
        }
        // Existing public XRP ledger fixtures; no private key is needed for a dry run.
        let sender = "r9cZA1mLK5R5Am25ArfXFmqgNwjZgnfk59"
        let recipient = "rLxePHrWeHbkg8yy83fWxnxXmYbwmuMK9Q"
        for apiKey: String? in [key, nil] {
            let transport = XrplQuoteOnlyTransport()
            let client = try XrplSendClient(network: .mainnet, apiKey: apiKey, transport: transport)
            for maximum in [false, true] {
                let start = Date.now
                let plan = try await client.quote(sender: sender, recipient: recipient,
                    reference: "native", amount: "730433", maximum: maximum)
                XCTAssertEqual(plan.network, .mainnet)
                XCTAssertEqual(plan.sender, sender); XCTAssertEqual(plan.recipient, recipient)
                XCTAssertGreaterThan(plan.fee, 0); XCTAssertLessThanOrEqual(plan.fee, XrplSendPlan.maximumFee)
                XCTAssertEqual(plan.amount, maximum ? String(plan.nativeBalance-plan.reserve-plan.fee) : "730433")
                XCTAssertGreaterThanOrEqual(try XCTUnwrap(UInt64(plan.remaining)), plan.reserve)
                XCTAssertNoThrow(try plan.validate())
                print("XRPL_MAINNET_QUOTE_VERIFIED provider=\(apiKey == nil ? "fallback" : "configured") max=\(maximum) fee_drops=\(plan.fee) seconds=\(String(format: "%.2f", Date.now.timeIntervalSince(start))) broadcast=false")
            }
            let methods = await transport.methods
            XCTAssertTrue(methods.contains("simulate"))
            XCTAssertFalse(methods.contains("submit"))
        }
    }
}
