import Foundation
import XCTest
@testable import OathAnkr

final class VerifiedEVMTokenCatalogTests: XCTestCase {
    private let contract = "0x" + String(repeating: "a", count: 40)
    private func data(chain: Int = 1, address: String? = nil, decimals: Int = 6) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tokens": [["chainId": chain, "address": address ?? contract, "decimals": decimals]]])
    }
    func testExactIdentityNormalizationAndNoSymbolTrust() throws {
        let result = try VerifiedEVMTokenCatalog.decode(data(address: "0x" + String(repeating: "A", count: 40)), chain: .eth)
        XCTAssertEqual(result.networkID, "ethereum")
        XCTAssertEqual(result.decimalsByReference, [contract: 6])
        XCTAssertNil(result.referencesWithoutDecimals)
        let restored = try JSONDecoder().decode(VerifiedEVMTokenCatalog.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.decimalsByReference, result.decimalsByReference)
    }
    func testWrongChainMalformedAddressAndPrecisionAreRejected() throws {
        for bytes in [try data(chain: 137), try data(address: "USDT"), try data(decimals: -1), try data(decimals: 256), Data("{\"tokens\":[]}".utf8)] {
            XCTAssertThrowsError(try VerifiedEVMTokenCatalog.decode(bytes, chain: .eth))
        }
        let conflict = try JSONSerialization.data(withJSONObject: ["tokens": [
            ["chainId": 1, "address": contract, "decimals": 6], ["chainId": 1, "address": contract, "decimals": 18]]])
        XCTAssertThrowsError(try VerifiedEVMTokenCatalog.decode(conflict, chain: .eth))
    }
    func testTaikoDirectoryUsesExactPlatformNotTickerOrPrice() throws {
        let bytes = try JSONSerialization.data(withJSONObject: [
            ["id": "usdt", "platforms": ["taiko": contract]],
            ["id": "other-chain", "platforms": ["ethereum": "0x" + String(repeating: "b", count: 40)]]])
        let result = try VerifiedEVMTokenCatalog.decodeCoinList(bytes, chain: .taiko)
        XCTAssertEqual(result.referencesWithoutDecimals, [contract])
        XCTAssertTrue(result.decimalsByReference.isEmpty)
        XCTAssertThrowsError(try VerifiedEVMTokenCatalog.decodeCoinList(bytes, chain: .base))
    }
    func testOldTONMetadataDecodesAndBlacklistIsPreserved() throws {
        let old = Data("{\"reference\":\"native\",\"name\":\"Gram\",\"symbol\":\"GRAM\",\"decimals\":9,\"verified\":true}".utf8)
        XCTAssertNil(try JSONDecoder().decode(TonToken.self, from: old).isBlacklisted)
        let value = try JSONDecoder().decode(TonJSON.self, from: Data("{\"address\":\"0:\(String(repeating: "a", count: 64))\",\"name\":\"Token\",\"symbol\":\"TKN\",\"decimals\":9,\"verification\":\"blacklist\"}".utf8))
        let token = try TonToken.decode(value)
        XCTAssertTrue(token.isBlacklisted == true)
        XCTAssertFalse(token.verified)
    }
}
