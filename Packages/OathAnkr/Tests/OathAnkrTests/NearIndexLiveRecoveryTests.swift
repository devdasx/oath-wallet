import Foundation
import XCTest
@testable import OathAnkr

private actor NearLiveRecoveryTransport: AnkrTransport {
    let live = AnkrHTTPTransport()
    var attempts: [String: Int] = [:]
    var successful: [String: Data] = [:]
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url!.path
        if request.url!.host!.hasSuffix("fastnear.com") {
            attempts[path, default: 0] += 1
            // Inject a lost connection before the first real query. The retry
            // must run the production transport against the public network.
            if attempts[path] == 1 { throw URLError(.networkConnectionLost) }
        }
        let response = try await live.send(request)
        if response.1 == 200 { successful[path] = response.0 }
        return response
    }
}

final class NearIndexLiveRecoveryTests: XCTestCase, @unchecked Sendable {
    func testLivePublicHistoryRecoversAndMatchesProviderData() async throws {
        guard ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_RECOVERY"] == "1" else {
            throw XCTSkip("Opt-in public network read; no wallet or signing keys required")
        }
        let transport = NearLiveRecoveryTransport()
        let client = try NearClient(endpoint: URL(string: "https://rpc.mainnet.near.org")!, transport: transport)
        let discovery = try await client.discovery(owner: "root.near")
        XCTAssertEqual(discovery["account_id"].string, "root.near")
        for (stream, path) in [("transfers", "/v0/transfers"), ("transactions", "/v0/account")] {
            let page = try await client.history(owner: "root.near", stream: stream, limit: 5)
            let received = await transport.successful[path]
            let data = try XCTUnwrap(received)
            let expected = try NearDecoding.history(JSONDecoder().decode(NearJSON.self, from: data), owner: "root.near", stream: stream, raw: data)
            XCTAssertEqual(page.ids, expected.ids)
            XCTAssertEqual(page.next, expected.next)
            XCTAssertFalse(page.ids.isEmpty)
            XCTAssertEqual(page.events.map(\.amount), expected.events.map(\.amount))
            XCTAssertEqual(page.events.map(\.counterparty), expected.events.map(\.counterparty))
            if stream == "transactions" {
                XCTAssertTrue(page.executions.allSatisfy { $0.fee != nil && $0.raw.count > 100 })
            }
        }
        let attempts = await transport.attempts
        for path in ["/v1/account/root.near/ft", "/v0/transfers", "/v0/account", "/v0/transactions"] {
            XCTAssertEqual(attempts[path], 2)
        }
    }
}
