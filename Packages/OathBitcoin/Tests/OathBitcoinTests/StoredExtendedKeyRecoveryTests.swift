import Foundation
import XCTest
@testable import OathBitcoin

final class StoredExtendedKeyRecoveryTests: XCTestCase {
    private let scalar = Data(hex: "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798")!
    private func wire(_ version: UInt32, _ marker: UInt8) -> String {
        let prefix = (0..<4).reversed().map { UInt8(truncatingIfNeeded:version >> ($0*8)) }
        return Base58Check.encode(Data(prefix) + Data(repeating:0,count:9) + Data(repeating:7,count:32) + Data([marker]) + scalar)
    }
    func testRecoveryRestoresEachOriginalScript() throws {
        // Independent compressed-point and HMAC-SHA512 BIP44 vectors for the synthetic stored scalar.
        let cases: [(UTXONetwork,UInt32,String)] = [
            (.bitcoin,0x0488ade4,"76a914e0e8af589bdee73f75ec22cee11351d6d51890cf88ac"),
            (.bitcoincash,0x0488ade4,"76a9149f160d8e21418d558e25585ecef4553f6188f32188ac"),
            (.dogecoin,0x02fac398,"76a9143102f8ba4115ad8945e19c0021d321232d73a8d488ac"),
            (.litecoin,0x019d9cfe,"76a9140fa3e61e5b79d95d721b2dbef3da5256f993117088ac")
        ]
        for (network,version,expectedScript) in cases {
            let canonical = try network.restoredExtendedPrivateKey(wire(version,2), storedScalar:scalar)
            XCTAssertTrue(canonical == wire(version,0))
            let wallet = try network.extended(canonical)
            let branch = try XCTUnwrap(wallet.branches.first { $0.type == .legacy && $0.change == 0 })
            let first = try XCTUnwrap(BitcoinKeys.addresses(branch:branch,range:0..<1).first)
            XCTAssertEqual(first.script,expectedScript)
            let wif = try network.privateKeyWIF(source:.extended(canonical), address:first)
            let leaf = try network.decodeImport(wif)
            let single = try network.singleKey(bytes: leaf.bytes, compressed:leaf.compressed)
            let same = try XCTUnwrap(single.branches.first { $0.type == .legacy })
            XCTAssertEqual(try BitcoinKeys.addresses(branch:same,range:0..<1).first?.script,expectedScript)
        }
    }
    func testRecoveryRefusesMismatchedStoredScalar() {
        XCTAssertThrowsError(try UTXONetwork.bitcoin.restoredExtendedPrivateKey(wire(0x0488ade4,2),storedScalar:Data(repeating:1,count:32)))
    }
    func testRecoveryRefusesPublicAndWrongNetworkVersions() {
        XCTAssertThrowsError(try UTXONetwork.bitcoin.restoredExtendedPrivateKey(wire(0x0488b21e,2),storedScalar:scalar))
        XCTAssertThrowsError(try UTXONetwork.bitcoin.restoredExtendedPrivateKey(wire(0x02fac398,2),storedScalar:scalar))
    }
}
