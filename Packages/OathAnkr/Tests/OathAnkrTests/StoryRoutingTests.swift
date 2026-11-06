import XCTest
@testable import OathAnkr

private actor StoryRPCFixture: AnkrTransport {
    var methods: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [[String: Any]])
        let replies = try calls.map { call -> [String: Any] in
            let method = try XCTUnwrap(call["method"] as? String)
            methods.append(method)
            let value: Any
            switch method {
            case "eth_chainId": value = "0x5ea"
            case "eth_blockNumber": value = "0x64"
            case "eth_getLogs": value = [] as [String]
            default: throw AnkrError.invalidResponse
            }
            return ["jsonrpc": "2.0", "id": call["id"]!, "result": value]
        }
        return (try JSONSerialization.data(withJSONObject: replies), 200)
    }
}
private struct StoryQuoteFixture: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "coins.llama.fi", request.url?.path.hasSuffix("coingecko:story-2") == true else {
            throw AnkrError.invalidResponse
        }
        return (try JSONSerialization.data(withJSONObject: ["coins": ["coingecko:story-2": ["price": 1.23,
            "confidence": 1, "timestamp": Int(Date().timeIntervalSince1970)]]]), 200)
    }
}
final class StoryRoutingTests: XCTestCase, @unchecked Sendable {
    func testPermissionsUseWorkingRPCAndRetainPartialCoverage() async throws {
        let transport = StoryRPCFixture()
        let client = try EVMSendClient(network: .story, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        let result = try await PermissionDiscovery(apiKey: "fixture", transport: transport).evm(network: .story,
            owner: "0x1111111111111111111111111111111111111111", client: client)
        XCTAssertEqual(result.coverage, .partial)
        XCTAssertTrue(result.permissions.isEmpty)
        let methods = await transport.methods
        XCTAssertTrue(methods.contains("eth_getLogs"))
        XCTAssertFalse(methods.contains { $0.hasPrefix("ankr_") })
    }
    func testStoryNativeQuoteUsesExactCoinIdentity() async throws {
        let price = try await IndexedEVMMarkets(chain: .story, transport: StoryQuoteFixture()).nativePrice()
        XCTAssertEqual(price.chain, .story)
        XCTAssertEqual(price.reference, "native")
        XCTAssertEqual(price.usd, "1.23")
    }
}
