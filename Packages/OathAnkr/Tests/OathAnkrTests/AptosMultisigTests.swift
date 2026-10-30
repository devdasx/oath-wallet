import XCTest
@testable import OathAnkr

@MainActor final class AptosMultisigTests: XCTestCase {
    func testOfficialSDKPoliciesAndTransactions() throws {
        struct Vector: Decodable {
            let required: Int, count: Int, chainID: Int, indices: [Int]
            let reference: String, sender: String, recipient: String, publicKey: String, publicKeys: [String]
            let raw: String, signatures: [String], signed: String, hash: String
        }
        let url = Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/AptosMultisig")!
        for v in try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url)) {
            let policy = try AptosMultisigPolicy(required: v.required, publicKeys: v.publicKeys.map(TronIdentity.hex))
            XCTAssertEqual(policy.address, v.sender)
            XCTAssertEqual(policy.bytes, try TronIdentity.hex(v.publicKey))
            let p = AptosSendPlan(network: v.chainID == 1 ? .mainnet : .testnet, sender: v.sender, recipient: v.recipient, reference: try AptosIdentity.reference(v.reference), publicKey: policy.bytes,
                decimals: v.reference == "native" ? 8 : 6, requestedAmount: 123456, amount: 123456, assetBalance: 100_000_000, nativeBalance: 100_000_000,
                sequence: 7, gasUnitPrice: 100, maxGasAmount: 2000, expiration: 2_000_000_300, createdAt: Date(timeIntervalSince1970: 2_000_000_000), multisig: policy)
            try p.validate(now: p.createdAt)
            XCTAssertEqual(try AptosSendCrypto.raw(p), try TronIdentity.hex(v.raw))
            let sigs = try zip(v.indices, v.signatures).map { try AptosMultisigSignature(index: $0, signature: TronIdentity.hex($1)) }
            let signed = try AptosSignedSend(bytes: TronIdentity.hex(v.signed), publicKey: policy.bytes, signature: Data(), hash: v.hash, signatures: sigs)
            try AptosSendCrypto.verify(signed, plan: p)
            let fields: [String: AptosJSON] = [
                "type": .string("single_sender"), "signatures_required": .number(String(v.required)),
                "public_keys": .array(v.publicKeys.map { .object(["type": .string("ed25519"), "value": .string($0)]) }),
                "signatures": .array(zip(v.indices, v.signatures).map { .object(["index": .number(String($0)), "signature": .object(["type": .string("ed25519"), "value": .string($1)])]) })
            ]
            try AptosSendCrypto.verifyMultisigResponse(.object(fields), signed: signed, policy: policy)
            for field in ["type", "signatures_required", "public_keys", "signatures"] {
                var changed = fields; changed[field] = .null
                XCTAssertThrowsError(try AptosSendCrypto.verifyMultisigResponse(.object(changed), signed: signed, policy: policy))
            }
            let allKeys = try (0..<v.count).map { i -> (Data, Data) in
                let key = Data(repeating: UInt8(i + 10), count: 32)
                return (key, try AptosSendCrypto.publicKey(privateKey: key))
            }.sorted { $0.1.lexicographicallyPrecedes($1.1) }
            let keys = v.indices.map { allKeys[$0].0 }
            try AptosSendCrypto.verify(AptosSendCrypto.sign(p, privateKeys: keys, now: p.createdAt), plan: p)
            XCTAssertThrowsError(try AptosSendCrypto.sign(p, privateKeys: Array(keys.dropLast()), now: p.createdAt))
            XCTAssertThrowsError(try AptosSendCrypto.sign(p, privateKey: keys[0], now: p.createdAt))
            var wrong = signed.bytes; wrong[0] ^= 1
            XCTAssertThrowsError(try AptosSendCrypto.verify(.init(bytes: wrong, publicKey: policy.bytes, signature: Data(), hash: AptosSendCrypto.hash(wrong), signatures: sigs), plan: p))
            if keys.count > 1 {
                XCTAssertThrowsError(try AptosSendCrypto.sign(p, privateKeys: Array(repeating: keys[0], count: keys.count), now: p.createdAt))
            }
        }
    }
    func testTestnetInventoryNeverUsesMainnetProviders() async throws {
        let transport = WrongAptosNetworkTransport()
        let client = AptosClient(network: .testnet, transport: transport)
        do { _ = try await client.inventory(owner: "0x123"); XCTFail("Wrong chain accepted") }
        catch { XCTAssertEqual(error as? AptosError, .wrongNetwork) }
        let hosts = await transport.hosts
        XCTAssertFalse(hosts.isEmpty)
        XCTAssertTrue(hosts.allSatisfy { $0 == "api.testnet.aptoslabs.com" })
    }
    func testMalformedPoliciesCannotDecodeOrChangeAccount() throws {
        let a = try AptosSendCrypto.publicKey(privateKey: Data(repeating: 1, count: 32))
        let b = try AptosSendCrypto.publicKey(privateKey: Data(repeating: 2, count: 32))
        XCTAssertThrowsError(try AptosMultisigPolicy(required: 1, publicKeys: (0..<33).map { Data(repeating: UInt8($0), count: 32) }))
        XCTAssertThrowsError(try AptosMultisigPolicy(required: 1, publicKeys: [a,a]))
        XCTAssertThrowsError(try AptosMultisigPolicy(required: 0, publicKeys: [a,b]))
        XCTAssertThrowsError(try AptosMultisigPolicy(required: 3, publicKeys: [a,b]))
        for n in [-1, 0, 3, 256, Int.max] {
            let bytes = try JSONSerialization.data(withJSONObject: ["required": n, "publicKeys": [a.base64EncodedString(),b.base64EncodedString()]])
            XCTAssertThrowsError(try JSONDecoder().decode(AptosMultisigPolicy.self, from: bytes))
        }
        XCTAssertNotEqual(try AptosMultisigPolicy(required: 1, publicKeys: [a,b]).address, try AptosMultisigPolicy(required: 2, publicKeys: [a,b]).address)
        XCTAssertEqual(try AptosMultisigPolicy(required: 1, publicKeys: [a,b]), try AptosMultisigPolicy(required: 1, publicKeys: [b,a]))
    }
}

private actor WrongAptosNetworkTransport: AnkrTransport {
    var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        hosts.append(request.url!.host!)
        return (Data(#"{"chain_id":1,"ledger_version":"100"}"#.utf8), 200)
    }
}
