import Foundation
import XCTest
@testable import OathAnkr

final class TronDiscoveryRegressionTests: XCTestCase, @unchecked Sendable {
    func testConfirmedNFTIsExcludedWhileBrokenFungibleMetadataStaysIncomplete() async throws {
        for nft in [true, false] {
            let client = try TronClient(apiKey: "fixture", transport: TokenClassificationTransport(nft: nft))
            let value = try await client.inventory(owner: TronTests.owner, additionalTokens: [TronIdentity.usdt])
            XCTAssertEqual(value.holdings.map(\.token.reference), ["native"])
            XCTAssertEqual(value.excludedNFTs, nft ? [TronIdentity.usdt] : [])
            XCTAssertEqual(value.failedReferences, nft ? [] : [TronIdentity.usdt])
            XCTAssertTrue(value.discoveryComplete)
        }
    }
}
private struct TokenClassificationTransport: AnkrTransport {
    let nft: Bool
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let value: TronJSON
        if request.url?.host == "api.trongrid.io" {
            value = .object(["success": .bool(true), "data": .array([])])
        } else if request.url?.path.hasSuffix("wallet/getaccount") == true {
            value = .object(["address": .string(TronTests.owner), "balance": .number("123")])
        } else {
            let calls = try JSONDecoder().decode(TronJSON.self, from: request.httpBody!).array!
            value = .array(calls.map { call in
                let method = call["method"].string
                let data = call["params"].array?.first?["data"].string ?? ""
                let result: String
                if method == "eth_chainId" { result = "0x2b6653dc" }
                else if data.hasPrefix("0x70a08231") { result = "0x" + String(repeating: "0", count: 63) + "1" }
                else if data.hasPrefix("0x01ffc9a7") { result = "0x" + String(repeating: "0", count: 63) + (nft ? "1" : "0") }
                else { result = "0x" } // ERC165 distinguishes missing fungible decimals from an NFT.
                return .object(["jsonrpc": .string("2.0"), "id": call["id"], "result": .string(result)])
            })
        }
        return (try JSONEncoder().encode(value), 200)
    }
}
