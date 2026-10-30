import Foundation
import XCTest
@testable import OathBitcoin

final class UTXOPrivateKeyImportTests: XCTestCase {
    func testHexPrefixCasePreservesExactScalarAndWalletIdentityForEveryFamily() throws {
        // Synthetic, unfunded scalars only. Prefix/case normalization must not
        // change compression, choose another network, or invent an HD parent.
        for scalar in [String(repeating: "0", count: 63) + "1", String(repeating: "0", count: 58) + "aBcDeF"] {
            let expected = try XCTUnwrap(Data(hex: scalar))
            for network: UTXONetwork in [.bitcoin, .bitcoincash, .litecoin, .dogecoin] {
                let canonical = try network.decodeImport(scalar)
                let descriptor = try network.singleKey(bytes: canonical.bytes, compressed: canonical.compressed)
                let addresses = try descriptor.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 0..<1) }.map(\.address)
                for prefix in ["", "0x", "0X"] {
                    for body in [scalar.lowercased(), scalar.uppercased(), scalar] {
                        let parsed = try network.decodeImport(prefix + body)
                        XCTAssertEqual(parsed.bytes, expected, network.rawValue)
                        XCTAssertTrue(parsed.compressed)
                        XCTAssertNil(parsed.extended)
                        let actual = try network.singleKey(bytes: parsed.bytes, compressed: parsed.compressed)
                        XCTAssertEqual(try actual.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 0..<1) }.map(\.address), addresses)
                    }
                }
            }
        }
    }

    func testHexNormalizationNeverAcceptsInvalidScalarOrChangesNetworkValidation() throws {
        let zero = String(repeating: "0", count: 64)
        let curveOrder = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"
        for network: UTXONetwork in [.bitcoin, .bitcoincash, .litecoin, .dogecoin] {
            for prefix in ["", "0x", "0X"] {
                for body in [zero, curveOrder, String(repeating: "f", count: 64), "1", String(repeating: "a", count: 63),
                             String(repeating: "a", count: 65), String(repeating: "g", count: 64)] {
                    XCTAssertThrowsError(try network.decodeImport(prefix + body), network.rawValue)
                }
            }
            let bytes = Data(repeating: 0, count: 31) + Data([1])
            let testnetWIF = Base58Check.encode(Data([0xef]) + bytes + Data([1]))
            XCTAssertThrowsError(try network.decodeImport(testnetWIF))
        }
    }
}
