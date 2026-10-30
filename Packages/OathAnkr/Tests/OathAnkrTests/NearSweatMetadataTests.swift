import Foundation
import XCTest
@testable import OathAnkr

private actor SweatMetadataTransport: AnkrTransport {
    let metadata: NearJSON
    let wrongBlock: Bool
    init(_ metadata: NearJSON, wrongBlock: Bool = false) {
        self.metadata = metadata; self.wrongBlock = wrongBlock
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let result = NearJSON.object([
            "block_hash": .string(NearTests.blockHash),
            "block_height": .number(wrongBlock ? "124" : "123"),
            "result": .array(try JSONEncoder().encode(metadata).map { .number(String($0)) })
        ])
        return (try JSONEncoder().encode(NearTests.result(result)), 200)
    }
}

@MainActor final class NearSweatMetadataTests: XCTestCase {
    // Public token.sweat ft_metadata response observed on 2026-10-30.
    // Only metadata fields needed by the parser; no wallet or request data.
    private var fields: [String: NearJSON] {
        ["spec": .string("ft-1.0"), "name": .string("SWEAT"),
         "symbol": .string("SWEAT"), "decimals": .number("18")]
    }
    func testPublicSweatMetadataThroughPinnedClient() async throws {
        let client = try NearClient(apiKey: "fixture", transport: SweatMetadataTransport(.object(fields)))
        let block = NearBlock(hash: NearTests.blockHash, height: 123, timestamp: 1700000000)
        let token = try await client.token("token.sweat", block: block)
        XCTAssertEqual(token.reference, "token.sweat")
        XCTAssertEqual(token.decimals, 18)
        XCTAssertEqual(token.symbol, "SWEAT")
        XCTAssertEqual(token.name, "SWEAT")
    }
    func testCompatibilityDoesNotAcceptOtherContractsOrInvalidMetadata() throws {
        XCTAssertThrowsError(try NearToken.decode(.object(fields), reference: "other.near"))
        for (key, value) in [("spec", NearJSON.string("ft-2.0")), ("spec", .null),
                             ("name", .null), ("symbol", .null), ("decimals", .number("256")),
                             ("decimals", .number("-1")), ("decimals", .number("1.5"))] {
            var malformed = fields; malformed[key] = value
            XCTAssertThrowsError(try NearToken.decode(.object(malformed), reference: "token.sweat"), key)
        }
        var standard = fields; standard["spec"] = .string("ft-1.0.0")
        XCTAssertEqual(try NearToken.decode(.object(standard), reference: "other.near").decimals, 18)
    }
    func testCompatibilityCannotBypassPinnedBlockValidation() async throws {
        let client = try NearClient(apiKey: "fixture", transport: SweatMetadataTransport(.object(fields), wrongBlock: true))
        do {
            _ = try await client.token("token.sweat", block: .init(hash: NearTests.blockHash, height: 123, timestamp: 1700000000))
            XCTFail("Wrong block must remain rejected")
        } catch { XCTAssertEqual(error as? NearError, .wrongBlock) }
    }
    func testPublicSweatMetadataLiveThroughAnkr() async throws {
        guard let key = ProcessInfo.processInfo.environment["OATH_LIVE_NEAR_METADATA_KEY"] else {
            throw XCTSkip("Opt-in public ANKR metadata read")
        }
        // No fallback: this check must verify the configured ANKR provider.
        let client = try NearClient(endpoint: URL(string: "https://rpc.ankr.com/near")!.appendingPathComponent(key))
        let block = try await client.finalBlock()
        let token = try await client.token("token.sweat", block: block)
        XCTAssertEqual(token.decimals, 18)
        XCTAssertEqual(token.symbol, "SWEAT")
    }
}
