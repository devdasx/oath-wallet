import XCTest
import CryptoKit
@testable import OathAnkr

final class SolanaSendTests:XCTestCase {
    struct Fixtures:Decodable { let vectors:[Vector],pdas:[PDA] }
    struct Vector:Decodable { let kind:String,sender:String,recipient:String,mint:String,program:String,source:String,destination:String,hash:String,message:String,bytes:String,referenceMessage:String; let references:[String] }
    struct PDA:Decodable { let owner:String,mint:String,program:String,address:String }
    func fixtures() throws -> Fixtures { try JSONDecoder().decode(Fixtures.self,from:Data(contentsOf:Bundle.module.url(forResource:"vectors",withExtension:"json",subdirectory:"Fixtures/SolanaSend")!)) }
    func plan(_ v:Vector,network:SolanaSendNetwork = .devnet) -> SolanaSendPlan {
        .init(network:network,sender:v.sender,recipient:v.recipient,reference:v.kind=="native" ? "native":v.mint,program:v.kind=="native" ? "":v.program,decimals:v.kind=="native" ? 9:6,
              requestedAmount:1234567,amount:1234567,assetBalance:100000000,nativeBalance:100000000,blockhash:v.hash,lastValidBlockHeight:500,slot:300,transactionFee:5247,
              rent:v.kind=="native" ? 0:2039280,computeUnits:200000,microLamports:1234,sources:v.kind=="native" ? []:[.init(address:v.source,amount:1234567)],tokenFees:v.kind=="transferFee" ? [12346]:[])
    }
    func testIndependentSDKMessagesAndSignaturesForBothTokenPrograms() throws {
        for v in try fixtures().vectors {
            let p=plan(v),signed=try SolanaSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
            XCTAssertEqual(try SolanaSendCrypto.message(p).base64EncodedString(),v.message,v.kind)
            let sdkBytes=Data(base64Encoded:v.bytes)!,sdkSignature=Data(sdkBytes[1..<65])
            try SolanaSendCrypto.verify(.init(bytes:sdkBytes,publicKey:signed.publicKey,signature:sdkSignature,hash:SolanaSendCrypto.encode(sdkSignature)),plan:p)
            try SolanaSendCrypto.verify(signed,plan:p)
            XCTAssertThrowsError(try SolanaSendCrypto.sign(p,privateKey:Data(repeating:2,count:32)))
            XCTAssertThrowsError(try SolanaSendCrypto.verify(.init(bytes:signed.bytes,publicKey:signed.publicKey,signature:Data(repeating:0,count:64),hash:signed.hash),plan:p))
        }
    }
    func testAssociatedAddressesAgainst128IndependentSDKDerivations() throws {
        for p in try fixtures().pdas { XCTAssertEqual(try SolanaSendCrypto.associatedAddress(owner:p.owner,mint:p.mint,program:p.program),p.address) }
        for n in 0..<64 { XCTAssertTrue(SolanaCurve.isPoint(try SolanaSendCrypto.publicKey(privateKey:Data(repeating:UInt8(n),count:32)))) }
    }
    func testExpiredQuoteNeverSignsButExistingSignatureRemainsVerifiable() throws {
        let v=try fixtures().vectors[0],p=plan(v),signed=try SolanaSendCrypto.sign(p,privateKey:Data(repeating:1,count:32))
        XCTAssertThrowsError(try p.validate(now:p.createdAt.addingTimeInterval(46)))
        try SolanaSendCrypto.verify(signed,plan:p)
        XCTAssertEqual(try SolanaSendCrypto.decode(signed.hash),signed.signature)
    }
    func testExactIntegersAndCheckedTransferFee() throws {
        let v=try fixtures().vectors[3],p=plan(v)
        XCTAssertEqual(p.receivedAmount,1222221);XCTAssertEqual(p.remaining,98765433)
        XCTAssertEqual(SolanaSendCrypto.le(UInt64.max),Data(repeating:255,count:8))
        XCTAssertEqual(SolanaSendCrypto.short(1232),Data([208,9]))
    }
    func testPaymentReferencesMatchIndependentSDKAndRemainReadOnly() throws {
        for vector in try fixtures().vectors {
            let original = plan(vector)
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            XCTAssertNil(json["paymentReferences"])
            json["paymentReferences"] = vector.references
            let referenced = try JSONDecoder().decode(SolanaSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(try SolanaSendCrypto.message(referenced).base64EncodedString(), vector.referenceMessage)
            let signed = try SolanaSendCrypto.sign(referenced, privateKey: Data(repeating: 1, count: 32))
            let decoded = try WalletConnectSolanaTransaction(bytes: signed.bytes, account: referenced.sender)
            let indices = try XCTUnwrap(decoded.instructions.last).accounts.suffix(vector.references.count)
            XCTAssertEqual(indices.map { decoded.keys[$0] }, vector.references)
            XCTAssertTrue(indices.allSatisfy { !decoded.writable.contains($0) && $0 >= decoded.signatureCount })
            XCTAssertThrowsError(try SolanaSendCrypto.verify(signed, plan: original))
            let writableAccount = vector.kind == "native" ? original.recipient : vector.source
            for invalid in [[original.sender], [writableAccount], Array(repeating: vector.references[0], count: 9), ["invalid"]] {
                json["paymentReferences"] = invalid
                let rejected = try JSONDecoder().decode(SolanaSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
                XCTAssertThrowsError(try SolanaSendCrypto.message(rejected))
            }
        }
    }
}
