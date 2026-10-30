import XCTest
import CryptoKit
@testable import OathAnkr

final class WalletConnectNearTests:XCTestCase {
    let key = Data(0..<32)
    func raw(nonce:UInt64 = 1, actions:[Data]? = nil) throws -> Data {
        let list = try actions ?? [Data([3]) + NearSendCrypto.u128("1000000000000000000000")]
        return try NearSendCrypto.text("sender.testnet") + Data([0]) + NearSendCrypto.publicKey(privateKey:key) + NearSendCrypto.le(nonce) + NearSendCrypto.text("recipient.testnet") + Data(repeating:3,count:32) + NearSendCrypto.le(UInt32(list.count)) + list.reduce(Data(),+)
    }
    func request(_ bytes:Data,account:String = "sender.testnet") throws -> WalletConnectNearRequest {
        try WalletConnectNearRequest(method:"near_signTransaction",chain:"near:testnet",account:account,params:JSONEncoder().encode(NearJSON.object(["transaction":WalletConnectNearRequest.buffer(bytes)])))
    }
    func testSDKVectorsAndExactSignatures() throws {
        let vectors = try JSONDecoder().decode([NearJSON].self,from:NearSendTests.fixture("vectors"))
        for v in vectors {
            let bytes = Data(base64Encoded:v["raw"].string!)!, r = try request(bytes), tx = try WalletConnectNearTransaction(bytes)
            XCTAssertEqual(tx.sender,"sender.testnet")
            let review = WalletConnectNearReview(request:r,fee:"1",transactions:[tx],createdAt:.now)
            let result = try r.sign(privateKey:key,review:review)
            let signed = Data(result["data"].array!.map{UInt8($0.integer!)})
            XCTAssertEqual(signed.prefix(bytes.count),bytes)
            XCTAssertEqual(signed[bytes.count],0)
            XCTAssertTrue(try Curve25519.Signing.PublicKey(rawRepresentation:tx.publicKey).isValidSignature(signed.suffix(64),for:Data(SHA256.hash(data:bytes))))
            XCTAssertEqual(SuiSendCrypto.base58(Data(SHA256.hash(data:bytes))),v["hash"].string)
        }
    }
    func testWrongOwnerKeyNetworkAndExpiredReview() throws {
        let bytes = try raw(); XCTAssertThrowsError(try request(bytes,account:"attacker.testnet"))
        let r = try request(bytes), tx = try WalletConnectNearTransaction(bytes)
        let review = WalletConnectNearReview(request:r,fee:"1",transactions:[tx],createdAt:.now)
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:1,count:32),review:review))
        XCTAssertThrowsError(try r.sign(privateKey:key,review:review,now:review.createdAt.addingTimeInterval(121)))
        XCTAssertThrowsError(try r.sign(privateKey:key,review:review,now:review.createdAt.addingTimeInterval(-1)))
        XCTAssertThrowsError(try request(raw(nonce:2)).sign(privateKey:key,review:review))
        XCTAssertNil(NearSendNetwork(walletConnectChain:"near:devnet"))
        XCTAssertNil(NearSendNetwork(walletConnectChain:"fake:testnet"))
    }
    func testRejectsMalformedBuffersDuplicateKeysAndTrailingBytes() throws {
        let bytes = try raw()
        XCTAssertThrowsError(try request(bytes + Data([0])))
        for i in 0..<bytes.count { XCTAssertThrowsError(try request(Data(bytes.prefix(i)))) }
        for params in ["{\"transaction\":{},\"transaction\":{}}", "{\"transaction\":{\"type\":\"Buffer\",\"data\":[256]}}", "{\"transaction\":{\"type\":\"Buffer\",\"data\":[1.0]}}", "{\"transaction\":{\"type\":\"Buffer\",\"data\":[-1]}}"] {
            XCTAssertThrowsError(try WalletConnectNearRequest(method:"near_signTransaction",chain:"near:testnet",account:"sender.testnet",params:Data(params.utf8)))
        }
    }
    func testOrderedBatchAndNoncePrecision() throws {
        let a = try raw(nonce:9_007_199_254_740_993), b = try raw(nonce:9_007_199_254_740_994)
        func batch(_ list:[Data]) throws -> WalletConnectNearRequest { try .init(method:"near_signTransactions",chain:"near:testnet",account:"sender.testnet",params:JSONEncoder().encode(NearJSON.object(["transactions":.array(list.map(WalletConnectNearRequest.buffer))]))) }
        XCTAssertEqual(try WalletConnectNearTransaction(a).nonce,9_007_199_254_740_993)
        XCTAssertEqual(try batch([a,b]).transactions,[a,b])
        XCTAssertThrowsError(try batch([a,a])); XCTAssertThrowsError(try batch([b,a])); XCTAssertThrowsError(try batch([]))
        XCTAssertThrowsError(try batch(Array(repeating:a,count:17)))
    }
    func testFunctionCallOverDefaultJSONArrayLimitAndExactArguments() throws {
        let args = Data(repeating:65,count:2048)
        let call = try NearSendCrypto.call("ft_transfer",args,50_000_000_000_000,"1")
        let r = try request(raw(actions:[call]))
        XCTAssertTrue(try WalletConnectNearTransaction(r.transactions[0]).actions[0].description.contains(args.base64EncodedString()))
        XCTAssertThrowsError(try WalletConnectJSON.decode(JSONEncoder().encode(WalletConnectNearRequest.buffer(r.transactions[0]))))
    }
    func testAllReviewedClassicActionKindsAndUnknownRejection() throws {
        let pub = try NearSendCrypto.publicKey(privateKey:key)
        let full = Data([5,0])+pub+NearSendCrypto.le(UInt64(0))+Data([1])
        let function = try Data([5,0])+pub+NearSendCrypto.le(UInt64(0))+Data([0,1])+NearSendCrypto.u128("250000000000000000000000")+NearSendCrypto.text("contract.testnet")+NearSendCrypto.le(UInt32(1))+NearSendCrypto.text("read")
        var list = [Data([0])]
        list.append(Data([1])+NearSendCrypto.blob(Data([0,97,115,109])))
        list.append(try NearSendCrypto.call("hello",Data("{}".utf8),1,"0"))
        list.append(try Data([3])+NearSendCrypto.u128("1"))
        list.append(try Data([4])+NearSendCrypto.u128("1")+Data([0])+pub)
        list.append(full); list.append(function); list.append(Data([6,0])+pub)
        list.append(Data([7])+NearSendCrypto.text("beneficiary.testnet"))
        let tx = try WalletConnectNearTransaction(raw(actions:list))
        XCTAssertEqual(tx.actions.map(\.kind),[0,1,2,3,4,5,5,6,7])
        XCTAssertTrue(tx.actions[5].description.contains("FULL ACCESS")); XCTAssertTrue(tx.actions[6].description.contains("250000000000000000000000"))
        XCTAssertTrue(tx.actions[8].description.contains("beneficiary.testnet"))
        XCTAssertThrowsError(try request(raw(actions:[Data([8])])))
    }
    func testAccountDiscoveryEnvelope() throws {
        let result = try WalletConnectNearRequest.accountResponse(account:"sender.testnet",publicKey:NearSendCrypto.publicKey(privateKey:key))
        XCTAssertEqual(result.array?.first?["accountId"].string,"sender.testnet")
        XCTAssertTrue(result.array!.first!["publicKey"].string!.hasPrefix("ed25519:"))
        XCTAssertThrowsError(try WalletConnectNearRequest(method:"near_getAccounts",chain:"near:testnet",account:"sender.testnet",params:Data("{\"extra\":1}".utf8)))
    }
}
