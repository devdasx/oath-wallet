import XCTest
@testable import OathAnkr

final class SuiMultisigTests: XCTestCase {
    struct Vector: Decodable { let network: SuiSendNetwork; let required, count: Int; let reference, sender, bytes, signature, digest: String; let keys, publicKeys: [String] }
    func testOfficialSDKVectorsBothNetworksAndTokens() throws {
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/SuiMultisig")!
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 20)
        for v in vectors {
            let keys = try v.keys.map(TronIdentity.hex), publicKeys = try keys.map(SuiSendCrypto.publicKey)
            let policy = try SuiMultisigPolicy(required: v.required, publicKeys: publicKeys)
            XCTAssertEqual(policy.address, v.sender)
            let funds = SuiSendFunds(coins: [], addressBalance: 1_000_000_000)
            let plan = try SuiSendPlan.make(network: v.network, sender: v.sender, recipient: "0xabc", reference: v.reference, amount: 1_000_000,
                native: funds, asset: funds, gasPrice: 1000, gasBudget: 5_000_000, epoch: 1252, nonce: 42, multisig: policy)
            let signed = try SuiSendCrypto.sign(plan, privateKeys: Array(keys.suffix(v.required)))
            XCTAssertEqual(signed.bytes.base64EncodedString(), v.bytes)
            // CryptoKit may randomize the Ed25519 nonce; verify the independent SDK signature rather than requiring byte identity.
            XCTAssertNoThrow(try SuiSendCrypto.verify(.init(bytes: signed.bytes, signature: Data(base64Encoded: v.signature)!, digest: v.digest), sender: v.sender))
            XCTAssertEqual(signed.digest, v.digest)
            XCTAssertNoThrow(try SuiSendCrypto.verify(signed, sender: v.sender))
            XCTAssertThrowsError(try SuiSendCrypto.sign(plan, privateKey: keys[0]))
            XCTAssertThrowsError(try SuiSendCrypto.sign(plan, privateKeys: Array(keys.prefix(v.required-1))))
            XCTAssertThrowsError(try SuiSendCrypto.sign(plan, privateKeys: Array(repeating: Data(repeating: 99, count: 32), count: v.required)))
            if v.required > 1 { XCTAssertThrowsError(try SuiSendCrypto.sign(plan, privateKeys: Array(repeating: keys[0], count: v.required))) }
            for index in [0,1,2,signed.signature.count-1] {
                var changed = signed.signature; changed[index] ^= 255
                XCTAssertThrowsError(try SuiSendCrypto.verify(.init(bytes: signed.bytes, signature: changed, digest: signed.digest), sender: v.sender))
            }
            for length in [0,1,2,67,signed.signature.count-1] {
                XCTAssertThrowsError(try SuiSendCrypto.verify(.init(bytes: signed.bytes, signature: Data(signed.signature.prefix(length)), digest: signed.digest), sender: v.sender))
            }
        }
    }
    func testInvalidPoliciesAndDecodedThresholdFailClosed() throws {
        let keys = try [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)].map(SuiSendCrypto.publicKey)
        for required in [0,3,Int.max] { XCTAssertThrowsError(try SuiMultisigPolicy(required: required, publicKeys: keys)) }
        XCTAssertThrowsError(try SuiMultisigPolicy(required: 1, publicKeys: [keys[0],keys[0]]))
        XCTAssertThrowsError(try SuiMultisigPolicy(required: 1, publicKeys: [keys[0]]))
        let policy = try SuiMultisigPolicy(required: 2, publicKeys: keys)
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)) as! [String:Any]
        json["required"] = Int.max
        XCTAssertThrowsError(try JSONDecoder().decode(SuiMultisigPolicy.self, from: JSONSerialization.data(withJSONObject: json)))
    }
}
