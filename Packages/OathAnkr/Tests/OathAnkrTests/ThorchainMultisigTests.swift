import XCTest
@testable import OathAnkr

final class ThorchainMultisigTests: XCTestCase {
    private func keys(_ count: Int) -> [Data] { (1...count).map { Data(repeating: 0, count: 31) + Data([UInt8($0)]) } }
    private func plan(required: Int = 2, count: Int = 3) throws -> ThorchainSendPlan {
        let p = try ThorchainMultisigPolicy(required: required, publicKeys: keys(count).map(ThorchainSendCrypto.publicKey))
        return try .init(network: .localTestnet, sender: p.address(network: .localTestnet),
            recipient: ThorchainSendCrypto.address(publicKey: ThorchainSendCrypto.publicKey(privateKey: keys(11)[10]), network: .localTestnet),
            reference: "native", memo: "Oath <&> \u{2028} test", publicKey: p.aminoPublicKey, decimals: 8,
            requestedAmount: "100", amount: "100", assetBalance: "10000000", nativeBalance: "10000000",
            accountNumber: 4, sequence: 2, fee: 2000000, height: 100, timeoutHeight: 130, multisig: p)
    }
    func testThresholdMatrixRoundTripAndCanonicalOrdering() throws {
        for count in 2...7 {
            for required in 1...count {
                let p = try plan(required: required, count: count)
                let selected = Array(keys(count).reversed().prefix(required))
                let signed = try ThorchainSendCrypto.sign(p, privateKeys: selected)
                try ThorchainSendCrypto.verify(signed, plan: p)
                XCTAssertEqual(try ThorchainSendCrypto.committedMultisigSequence(signed.bytes, plan: p), p.sequence)
                let recovered = try JSONDecoder().decode(ThorchainSendPlan.self, from: JSONEncoder().encode(p))
                XCTAssertEqual(recovered, p)
                try ThorchainSendCrypto.verify(JSONDecoder().decode(ThorchainSignedSend.self, from: JSONEncoder().encode(signed)), plan: recovered)
                XCTAssertEqual(try ThorchainSendCrypto.sign(p, privateKeys: selected.reversed()), signed)
                XCTAssertThrowsError(try ThorchainSendCrypto.sign(p, privateKeys: Array(selected.dropLast())))
                XCTAssertThrowsError(try ThorchainSendCrypto.sign(p, privateKeys: selected + [selected[0]]))
            }
        }
    }
    func testRejectsWrongKeysMutatedSignaturesWireAndPolicy() throws {
        let p = try plan(), signed = try ThorchainSendCrypto.sign(p, privateKeys: Array(keys(3).prefix(2)))
        XCTAssertThrowsError(try ThorchainSendCrypto.sign(p, privateKey: keys(1)[0]))
        XCTAssertThrowsError(try ThorchainSendCrypto.sign(p, privateKeys: [keys(1)[0],keys(11)[10]]))
        for offset in [0,1,2,10,signed.signature.count-1] {
            var sig = signed.signature; sig[offset] ^= 1
            XCTAssertThrowsError(try ThorchainSendCrypto.verify(.init(bytes: signed.bytes, signature: sig, hash: signed.hash), plan: p))
        }
        var wire = signed.bytes; wire[20] ^= 1
        XCTAssertThrowsError(try ThorchainSendCrypto.committedMultisigSequence(wire, plan: p))
        XCTAssertThrowsError(try ThorchainSendCrypto.verify(.init(bytes: wire, signature: signed.signature, hash: signed.hash), plan: p))
        XCTAssertThrowsError(try ThorchainMultisigPolicy(required: 0, publicKeys: p.multisig!.publicKeys))
        XCTAssertThrowsError(try ThorchainMultisigPolicy(required: 4, publicKeys: p.multisig!.publicKeys))
        XCTAssertThrowsError(try ThorchainMultisigPolicy(required: 2, publicKeys: [p.multisig!.publicKeys[0],p.multisig!.publicKeys[0]]))
        XCTAssertThrowsError(try ThorchainMultisigPolicy(required: 2, publicKeys: keys(8).map(ThorchainSendCrypto.publicKey)))
    }
}
