import Foundation
import XCTest
@testable import OathBitcoin

final class ExtendedKeyWireTests: XCTestCase {
    // Public secp256k1 generator x coordinate. It is public data, not a secret.
    private let knownX = Data(hex: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!
    private func key(_ version: UInt32, marker: UInt8, depth: UInt8 = 0) -> String {
        var wire = Data([UInt8(truncatingIfNeeded: version >> 24),UInt8(truncatingIfNeeded: version >> 16),UInt8(truncatingIfNeeded: version >> 8),UInt8(truncatingIfNeeded: version),depth])
        wire += Data(repeating:0,count:8) + Data(repeating:7,count:32) + Data([marker]) + knownX
        return Base58Check.encode(wire)
    }

    private func rejectPublicPoint(_ network: UTXONetwork, _ version: UInt32) throws {
        let forged = key(version, marker:2)
        do {
            let decoded = try network.decodeImport(forged)
            // Demonstrate actual private scalar substitution, not just parse acceptance.
            XCTAssertTrue(decoded.bytes == knownX && decoded.extended == forged)
            XCTFail("Public point accepted as private key material")
        } catch BitcoinError.invalidKey {}
    }
    func testBitcoinRejectsPublicPointInPrivateEnvelope() throws { try rejectPublicPoint(.bitcoin,0x0488ade4) }
    func testBitcoinCashRejectsPublicPointInPrivateEnvelope() throws { try rejectPublicPoint(.bitcoincash,0x0488ade4) }
    func testDogecoinRejectsPublicPointInPrivateEnvelope() throws { try rejectPublicPoint(.dogecoin,0x02fac398) }
    func testLitecoinRejectsPublicPointInPrivateEnvelope() throws { try rejectPublicPoint(.litecoin,0x019d9cfe) }
    func testCanonicalPrivateEnvelopesRetainOriginalScalar() throws {
        for (network,version) in [(UTXONetwork.bitcoin,UInt32(0x0488ade4)),(.bitcoincash,0x0488ade4),(.dogecoin,0x02fac398),(.litecoin,0x019d9cfe)] {
            let valid = key(version, marker:0)
            let decoded = try network.decodeImport(valid)
            XCTAssertTrue(decoded.bytes == knownX && decoded.extended == valid)
        }
    }

    func testAlternatePrivateVersionsRejectMalformedMarker() throws {
        for (network,version) in [(UTXONetwork.bitcoin,UInt32(0x049d7878)),(.bitcoin,0x04b2430c),(.litecoin,0x01b26792)] {
            for marker: UInt8 in [1,3,4,255] {
                do {
                    _ = try network.decodeImport(key(version, marker:marker))
                    XCTFail("Alternate private version accepted a nonzero marker")
                    return
                } catch BitcoinError.invalidKey {}
            }
        }
    }
    func testPublicVersionCannotBeImportedAsPrivate() throws {
        for network in [UTXONetwork.bitcoin,.litecoin,.dogecoin,.bitcoincash] {
            XCTAssertThrowsError(try network.decodeImport(key(0x0488b21e,marker:2)))
        }
    }
}
