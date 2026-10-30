import XCTest
@testable import OathAnkr

final class EVMSendTests:XCTestCase {
    struct Vector:Decodable { let network:EVMSendNetwork;let sender:String,recipient:String,reference:String,amount:String,raw:String,hash:String;let decimals:Int; let legacy:Bool }
    func vectors() throws -> [Vector] {
        let url=try XCTUnwrap(Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/EVMSend"))
        return try JSONDecoder().decode([Vector].self,from:Data(contentsOf:url))
    }
    func plan(_ v:Vector,now:Date = .now) -> EVMSendPlan {
        .init(network:v.network,sender:v.sender,recipient:v.recipient,reference:v.reference,decimals:v.decimals,requestedAmount:v.amount,amount:v.amount,
              assetBalance:"1000000000000000000000",nativeBalance:"1000000000000000000000",nonce:7,gasLimit:v.reference=="native" ? 21000:70000,
              maxFeePerGas:41000000000,maxPriorityFeePerGas:v.legacy ? 0:1000000000,blockHeight:100,createdAt:now,legacy:v.legacy)
    }
    func testNativeAndTokenSignaturesMatchIndependentEthersVectors() throws {
        for v in try vectors() {
            let p=plan(v),signed=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
            XCTAssertEqual(TronSendCrypto.hex(signed.bytes),v.raw);XCTAssertEqual(signed.hash,v.hash)
            try EVMSendCrypto.verify(signed,plan:p)
            var bytes=signed.bytes;bytes[20]^=1
            XCTAssertThrowsError(try EVMSendCrypto.verify(.init(bytes:bytes,signature:signed.signature,hash:signed.hash),plan:p))
            XCTAssertThrowsError(try EVMSendCrypto.sign(p,privateKey:Data(repeating:2,count:32)))
        }
    }
    func testExactUInt256AndNativeMirrorPrecision() throws {
        let maximum="115792089237316195423570985008687907853269984665640564039457584007913129639935"
        XCTAssertEqual(try EVMSendAmount.hex(maximum),"0x"+String(repeating:"f",count:64))
        XCTAssertEqual(try EVMSendAmount.add("18446744073709551615","1"),"18446744073709551616")
        XCTAssertThrowsError(try EVMSendAmount.add(maximum,"1"));XCTAssertThrowsError(try EVMSendAmount.subtract("0","1"))
        for n in ["01","-1","1.5","1e18",""] { XCTAssertThrowsError(try EVMSendAmount.checked(n)) }
        XCTAssertEqual(try EVMSendIdentity.reference("0x3600000000000000000000000000000000000000"),"0x3600000000000000000000000000000000000000")
    }
    func testDecodedPlanCannotBypassNetworkFeeAmountOrAgeValidation() throws {
        let p=plan(try vectors()[0]);var j=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        for (field,value) in [("gasLimit",UInt64.max as Any),("decimals",6 as Any),("amount","0" as Any),("recipient",p.sender as Any),("maxPriorityFeePerGas",UInt64.max as Any),("nonce",UInt64.max as Any)] {
            var changed=j;changed[field]=value
            let bad=try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:changed))
            XCTAssertThrowsError(try bad.validate(),field)
        }
        j["nativeBalance"]="1"
        XCTAssertThrowsError(try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:j)).validate())
        let old=plan(try vectors()[0],now:.now.addingTimeInterval(-100))
        XCTAssertThrowsError(try old.validate());try old.validate(checkAge:false)
    }
    func testSignatureIsBoundToChainRecipientNonceAndToken() throws {
        let p=plan(try vectors()[0]),s=try EVMSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        let j=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(p)) as? [String:Any])
        for (field,value) in [("network","ethereumSepolia" as Any),("nonce",8 as Any),("recipient","0x"+String(repeating:"3",count:40) as Any),("amount","123" as Any)] {
            var changed=j;changed[field]=value
            let altered=try JSONDecoder().decode(EVMSendPlan.self,from:JSONSerialization.data(withJSONObject:changed))
            XCTAssertThrowsError(try EVMSendCrypto.verify(s,plan:altered),field)
        }
    }
}
