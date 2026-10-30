import XCTest
@testable import OathAnkr

final class TronMultisigTests: XCTestCase {
    private func fixture() throws -> TronJSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "multisig-vector", withExtension: "json", subdirectory: "Fixtures/TronSend"))
        return try JSONDecoder().decode(TronJSON.self, from: Data(contentsOf: url))
    }
    private func plan(_ f: TronJSON, _ row: TronJSON) throws -> TronSendPlan {
        let keys = try XCTUnwrap(f["keys"].array).map { try TronIdentity.hex(XCTUnwrap($0.string)) }
        let count = Int(try XCTUnwrap(row["count"].integer)), required = Int(try XCTUnwrap(row["required"].integer))
        let policy = try TronMultisigPolicy(required: required, signers: keys.prefix(count).map { try TronSendCrypto.address(privateKey: $0) })
        let setup = row["reference"].string == "setup", limit = try XCTUnwrap(row["feeLimit"].integer), time = try XCTUnwrap(f["timestamp"].integer)
        return .init(network: .nile, sender: try XCTUnwrap(f["sender"].string), recipient: try XCTUnwrap(f[setup ? "sender" : "recipient"].string),
            reference: setup ? "native" : try XCTUnwrap(row["reference"].string), amount: setup ? "0" : "1234567", requestedAmount: setup ? "0" : "1234567",
            assetBalance: (setup || row["reference"].string == "native") ? "1000000000" : "10000000", decimals: 6,
            nativeBalance: 1_000_000_000, fee: 110_000_000, estimatedFee: 100_000_000, feeLimit: limit, energyPrice: 100, bandwidthPrice: 1000,
            blockID: try XCTUnwrap(f["blockID"].string), blockNumber: 71803059, timestamp: time, expiration: time + 180000,
            createdAt: Date(timeIntervalSince1970: Double(time)/1000), multisig: setup ? nil : policy, multisigSetup: setup ? policy : nil)
    }
    func testTronWebVectorsForEveryTransferAndThreshold() throws {
        let f = try fixture(), rows = try XCTUnwrap(f["vectors"].array)
        XCTAssertEqual(rows.count, 16)
        for row in rows {
            let p = try plan(f, row)
            let keys = try XCTUnwrap(f["keys"].array).prefix(p.multisig?.required ?? 0).map { try TronIdentity.hex(XCTUnwrap($0.string)) }
            let signed = try TronSendCrypto.sign(p, privateKeys: p.multisigSetup != nil ? [TronIdentity.hex(XCTUnwrap(f["bootstrap"].string))] : keys, now: p.createdAt)
            XCTAssertEqual(TronSendCrypto.hex(try TronSendCrypto.raw(p)), row["raw"].string)
            XCTAssertEqual(signed.hash, row["hash"].string)
            XCTAssertEqual(signed.signatures.map(TronSendCrypto.hex), row["signatures"].array?.compactMap(\.string).map { $0.lowercased() })
            XCTAssertEqual(TronSendCrypto.hex(signed.bytes), row["bytes"].string)
            try TronSendCrypto.verify(signed, plan: p)
            XCTAssertEqual(try JSONDecoder().decode(TronSignedSend.self, from: JSONEncoder().encode(signed)), signed)
        }
    }
    func testThresholdCannotBeBypassedByBootstrapDuplicateOrForeignKeys() throws {
        let f = try fixture(), row = try XCTUnwrap(f["vectors"].array?.first { $0["required"].integer == 2 && $0["reference"].string == "native" })
        let p = try plan(f, row), keys = try XCTUnwrap(f["keys"].array).map { try TronIdentity.hex(XCTUnwrap($0.string)) }
        for wrong in [[keys[0]], [keys[0],keys[0]], [keys[0],keys[4]], [try TronIdentity.hex(XCTUnwrap(f["bootstrap"].string))]] {
            XCTAssertThrowsError(try TronSendCrypto.sign(p, privateKeys: wrong, now: p.createdAt))
        }
        // Any valid subset can sign; the original account key has no special role.
        let signed = try TronSendCrypto.sign(p, privateKeys: [keys[1],keys[2]], now: p.createdAt)
        try TronSendCrypto.verify(signed, plan: p)
        var corrupted = signed.bytes; corrupted[20] ^= 1
        XCTAssertThrowsError(try TronSendCrypto.verify(.init(bytes: corrupted, signature: signed.signature, hash: signed.hash, additionalSignatures: signed.additionalSignatures), plan: p))
        XCTAssertThrowsError(try TronSendCrypto.verify(.init(bytes: signed.bytes, signature: signed.signature, hash: signed.hash), plan: p))
    }
    func testPolicyLimitsAndNoOwnerBackdoor() throws {
        let f = try fixture(), keys = try XCTUnwrap(f["keys"].array).map { try TronSendCrypto.address(privateKey: TronIdentity.hex(XCTUnwrap($0.string))) }
        for (m, members) in [(0,Array(keys.prefix(3))),(4,Array(keys.prefix(3))),(1,[keys[0]]),(2,[keys[0],keys[0]]),(2,keys+[try XCTUnwrap(f["sender"].string)])] {
            XCTAssertThrowsError(try TronMultisigPolicy(required: m, signers: members))
        }
        let p = try TronMultisigPolicy(required: 2, signers: Array(keys.prefix(3)))
        func permission(_ type: Int, threshold: Int, members: [String]) -> TronJSON {
            var value: [String: TronJSON] = ["type":.number(String(type)),"id":.number(type == 0 ? "0":"2"),"permission_name":.string(type == 0 ? "owner":"active"),"threshold":.number(String(threshold)),"keys":.array(members.map { .object(["address":.string($0),"weight":.number("1")]) })]
            if type == 2 { value["operations"] = .string(TronMultisigPolicy.operations) }
            return .object(value)
        }
        let active = permission(2, threshold: 2, members: Array(keys.prefix(3)))
        XCTAssertTrue(try p.matches(.object(["owner_permission":permission(0,threshold:2,members:Array(keys.prefix(3))),"active_permission":.array([active])])))
        XCTAssertFalse(try p.matches(.object(["owner_permission":permission(0,threshold:1,members:[keys[0]]),"active_permission":.array([active])])))
        XCTAssertFalse(try p.matches(.object(["owner_permission":permission(0,threshold:2,members:Array(keys.prefix(3))),"active_permission":.array([active,active])])))
        XCTAssertFalse(try p.matches(.object([:])))
    }
}
