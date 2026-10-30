import XCTest
@testable import OathAnkr

final class WalletConnectTronTests: XCTestCase {
    private func fixture() throws -> TronJSON {
        try JSONDecoder().decode(TronJSON.self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/WalletConnectTron"))))
    }
    private func parse(_ tx: TronJSON, _ fixture: TronJSON, legacy: Bool = false) throws -> WalletConnectTronRequest {
        try WalletConnectTronRequest(method: "tron_signTransaction", chain: TronSendNetwork.nile.walletConnectChain,
            account: fixture["account"].string!, params: JSONEncoder().encode(TronJSON.object([
                "address": fixture["account"], "transaction": legacy ? .object(["transaction": tx, "result":.object(["result":.bool(true)])]) : tx])),
            now: Date(timeIntervalSince1970: Double(fixture["timestamp"].integer!) / 1000))
    }
    func testIndependentTronWebTransactionsAndLegacyWrappers() throws {
        let f = try fixture(), key = try TronIdentity.hex(f["key"].string!)
        let now = Date(timeIntervalSince1970: Double(f["timestamp"].integer!) / 1000)
        for row in f["vectors"].array! {
            for legacy in [false, true] {
                let request = try parse(row["tx"], f, legacy: legacy)
                XCTAssertEqual(request.hash, row["tx"]["txID"].string)
                XCTAssertEqual(TronSendCrypto.hex(request.raw), row["tx"]["raw_data_hex"].string)
                XCTAssertEqual(request.memo, Data("Memo 🌍".utf8))
                let signed = try request.sign(privateKey: key, now: now)
                XCTAssertEqual(signed["signature"].array?.first?.string?.lowercased(), row["signature"].string?.lowercased())
                XCTAssertEqual(signed["txID"], row["tx"]["txID"])
                XCTAssertEqual(signed["visible"], .bool(false))
                var unsigned = signed.fields!; unsigned.removeValue(forKey: "signature")
                XCTAssertEqual(try parse(.object(unsigned), f).raw, request.raw)
                var rawOnly = row["tx"].fields!; rawOnly.removeValue(forKey:"raw_data_hex"); rawOnly.removeValue(forKey:"txID")
                XCTAssertEqual(try parse(.object(rawOnly), f, legacy: legacy).raw, request.raw)
                XCTAssertThrowsError(try request.sign(privateKey: Data(repeating:8,count:32), now: now))
                XCTAssertThrowsError(try request.sign(privateKey: key, now: now.addingTimeInterval(180)))
            }
        }
    }
    func testTIP191UTF8AndHexLookingTextMatchTronWeb() throws {
        let f = try fixture(), key = try TronIdentity.hex(f["key"].string!)
        for row in f["messages"].array! {
            let req = try WalletConnectTronRequest(method:"tron_signMessage", chain:TronSendNetwork.mainnet.walletConnectChain,
                account:f["account"].string!, params:JSONEncoder().encode(TronJSON.object(["address":f["account"],"message":row["message"]])))
            XCTAssertEqual(try req.sign(privateKey:key)["signature"].string?.lowercased(),row["signature"].string?.lowercased())
            XCTAssertEqual(req.message,row["message"].string)
        }
    }
    func testChangedBytesHashesOwnersAndPermissionsRejected() throws {
        let f = try fixture(), tx = f["vectors"].array![0]["tx"]
        for (key,value) in [("txID",TronJSON.string(String(repeating:"0",count:64))), ("raw_data_hex",.string("00")), ("signature",.array([.string("00")])), ("ret",.array([])), ("visible",.string("true"))] {
            var changed = tx.fields!; changed[key] = value
            XCTAssertThrowsError(try parse(.object(changed), f))
        }
        for field in ["Permission_id", "provider", "ContractName"] {
            var changed = tx.fields!, data = changed["raw_data"]!.fields!, contract = data["contract"]!.array![0].fields!
            contract[field] = .number("2"); data["contract"] = .array([.object(contract)]); changed["raw_data"] = .object(data)
            XCTAssertThrowsError(try parse(.object(changed),f))
        }
        var changed = tx.fields!, data = changed["raw_data"]!.fields!, contract = data["contract"]!.array![0].fields!, param = contract["parameter"]!.fields!, value = param["value"]!.fields!
        value["owner_address"] = .string(TronSendCrypto.hex(try TronIdentity.bytes(f["recipient"].string!)))
        param["value"] = .object(value); contract["parameter"] = .object(param); data["contract"] = .array([.object(contract)]); changed["raw_data"] = .object(data)
        XCTAssertThrowsError(try parse(.object(changed),f))
    }
    func testRejectsUnknownRawFieldsMultipleContractsAndExpiry() throws {
        let f = try fixture(), tx = f["vectors"].array![0]["tx"]
        for (field,value) in [("auths",TronJSON.array([])),("contract",.array([tx["raw_data"]["contract"].array![0],tx["raw_data"]["contract"].array![0]])),("expiration",.number("1")),("timestamp",.number("9223372036854775807")),("fee_limit",.number("9223372036854775807")),("ref_block_hash",.string("00")),("data",.string(String(repeating:"00",count:1025)))] {
            var changed = tx.fields!, data = changed["raw_data"]!.fields!; data[field] = value; changed["raw_data"] = .object(data)
            changed.removeValue(forKey:"raw_data_hex"); changed.removeValue(forKey:"txID")
            XCTAssertThrowsError(try parse(.object(changed),f))
        }
    }
    func testApprovalAndRevocationExactUint256AndUnknownContract() throws {
        let f = try fixture()
        let rows = Dictionary(uniqueKeysWithValues: f["vectors"].array!.map { ($0["kind"].string!,$0["tx"]) })
        let approve = try parse(rows["approve"]!,f), revoke = try parse(rows["revoke"]!,f), unknown = try parse(rows["contract"]!,f)
        XCTAssertEqual(approve.action,.approval); XCTAssertEqual(approve.amount,"115792089237316195423570985008687907853269984665640564039457584007913129639935")
        XCTAssertEqual(revoke.action,.approval); XCTAssertEqual(revoke.amount,"0")
        XCTAssertEqual(unknown.action,.contract); XCTAssertEqual(unknown.nativeValue,12)
        XCTAssertEqual(unknown.destination,f["token"].string)
    }
    func testTAPOSAllowsSmallNodeLagAcrossHeightWrap() throws {
        XCTAssertEqual(try WalletConnectTronRequest.referenceHeight(head: 72_285_773, bytes: Data([UInt8((72_285_774 >> 8) & 255), UInt8(72_285_774 & 255)])), 72_285_774)
        XCTAssertEqual(try WalletConnectTronRequest.referenceHeight(head: 65_535, bytes: Data([0, 0])), 65_536)
        XCTAssertEqual(try WalletConnectTronRequest.referenceHeight(head: 65_536, bytes: Data([255, 255])), 65_535)
        XCTAssertThrowsError(try WalletConnectTronRequest.referenceHeight(head: 1, bytes: Data([255, 255])))
    }
    func testNamespaceMethodAndAccountAreBound() throws {
        let f = try fixture(), params = try JSONEncoder().encode(TronJSON.object(["address":f["account"],"message":.string("Review")]))
        for chain in ["eip155:1", "tron:0x94a9059e", "tron:unknown"] {
            XCTAssertThrowsError(try WalletConnectTronRequest(method:"tron_signMessage",chain:chain,account:f["account"].string!,params:params))
        }
        for method in ["eth_sign", "tron_sendTransaction", "signMessage"] {
            XCTAssertThrowsError(try WalletConnectTronRequest(method:method,chain:TronSendNetwork.nile.walletConnectChain,account:f["account"].string!,params:params))
        }
        XCTAssertThrowsError(try WalletConnectTronRequest(method:"tron_signMessage",chain:TronSendNetwork.nile.walletConnectChain,account:f["recipient"].string!,params:params))
    }
}
