import XCTest
import CryptoKit
@testable import OathAnkr

final class WalletConnectSuiTests: XCTestCase {
    let account = "0xa0ccc8bcc83f6c628340134f8546a21e0618fd1aaa02432bba454c4a2c2233da"
    let bytes = "AAACAAhAQg8AAAAAAAAgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAICAgABAQAAAQECAAABAQCgzMi8yD9sYoNAE0+FRqIeBhj9GqoCQyu6RUxKLCIz2gEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAQEAAAAAAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAoMzIvMg/bGKDQBNPhUaiHgYY/RqqAkMrukVMSiwiM9roAwAAAAAAAICWmAAAAAAAAA=="
    func request(_ method:String = "sui_signTransaction", account:String? = nil, value:String? = nil) throws -> WalletConnectSuiRequest {
        let params = method == "sui_signPersonalMessage" ? ["address":account ?? self.account,"message":value ?? "Oath Sui test 🌍"] : ["address":account ?? self.account,"transaction":value ?? bytes]
        return try .init(method:method,chain:"sui:testnet",account:self.account,params:JSONEncoder().encode(params))
    }
    func review(_ request:WalletConnectSuiRequest, date:Date = .now) throws -> WalletConnectSuiReview {
        let parsed = try WalletConnectSuiTransaction(request.transaction!,network:.testnet,account:request.account,executing:request.broadcasts)
        return .init(request:request,changes:[],details:parsed.inputs+parsed.commands,gasOwner:parsed.gasOwner,gasBudget:parsed.gasBudget,estimatedFee:1,createdAt:date)
    }
    func testIndependentSDKTransactionAndSignature() throws {
        let request = try request(), review = try review(request)
        let result = try request.sign(privateKey:Data(repeating:7,count:32),review:review)
        let reference = Data(base64Encoded:"AEbEI6zAwVURmQetLlldcN0P6SxUqmMZ20bD0jM60X6ZyUqHvd6IQ/uI1RX/rWpGHJpfHpTnKpD5Ud2YCS1vHQ/qSmxj4pxSCr71UHsTLsX5lUd2rr6+e5JCHuppFEbSLA==")!
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:reference.suffix(32))
        let digest = SuiSendCrypto.hash(Data([0,0,0]) + Data(base64Encoded:bytes)!)
        XCTAssertTrue(publicKey.isValidSignature(reference.dropFirst().prefix(64),for:digest))
        XCTAssertTrue(publicKey.isValidSignature(Data(base64Encoded:result.signature)!.dropFirst().prefix(64),for:digest))
        XCTAssertEqual(result.response["transactionBytes"],bytes)
        XCTAssertEqual(review.gasBudget,10_000_000)
        XCTAssertEqual(review.details.count,4)
        try SuiSendCrypto.verify(result.transaction!,sender:account)
    }
    func testPersonalMessageIntentAndPlainText() throws {
        let result = try request("sui_signPersonalMessage").sign(privateKey:Data(repeating:7,count:32))
        let reference = Data(base64Encoded:"AHHBj67f7kqTa9H8RcAsxqLz4eQ6+sHsEaGFMNh/OwPy7PncMcnPahhCT/x8U0aVI098jtMLectlD2fghB3YeAHqSmxj4pxSCr71UHsTLsX5lUd2rr6+e5JCHuppFEbSLA==")!
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation:reference.suffix(32))
        let digest = SuiSendCrypto.hash(Data([3,0,0]) + SuiBCS.vector(Data("Oath Sui test 🌍".utf8)))
        XCTAssertTrue(publicKey.isValidSignature(reference.dropFirst().prefix(64),for:digest))
        XCTAssertTrue(publicKey.isValidSignature(Data(base64Encoded:result.signature)!.dropFirst().prefix(64),for:digest))
        XCTAssertNil(result.transaction)
        XCTAssertEqual(try request("sui_signPersonalMessage",value:"SGVsbG8=").message,Data("SGVsbG8=".utf8))
    }
    func testZeroVersionGasReferenceIsAccepted() throws {
        var raw = Data(base64Encoded:bytes)!
        // Version zero is used by the SDK for address-balance gas reservations.
        let versionOffset = raw.count - 8 - 8 - 32 - 1 - 33 - 8
        raw.replaceSubrange(versionOffset..<versionOffset+8,with:Data(repeating:0,count:8))
        XCTAssertNoThrow(try request(value:raw.base64EncodedString()))
    }
    func testAccountDiscovery() throws {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation:Data(repeating:7,count:32))
        XCTAssertEqual(try WalletConnectSuiRequest.accountResponse(publicKey:key.publicKey.rawRepresentation),[["address":account,"pubkey":"6kpsY+KcUgq+9VB7Ey7F+ZVHdq6+vnuSQh7qaRRG0iw="]])
        let r = try WalletConnectSuiRequest(method:"sui_getAccounts",chain:"sui:testnet",account:account,params:Data("{}".utf8))
        XCTAssertNil(r.transaction); XCTAssertFalse(r.broadcasts)
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:7,count:32)))
    }
    func testSponsorRequiresSignOnlyAndKeepsSenderBinding() throws {
        var raw = Data(base64Encoded:bytes)!
        let ownerOffset = raw.count - 1 - 8 - 8 - 32
        raw.replaceSubrange(ownerOffset..<ownerOffset+32,with:Data(repeating:2,count:32))
        let signOnly = try request(value:raw.base64EncodedString())
        XCTAssertNotEqual(try review(signOnly).gasOwner,account)
        XCTAssertNoThrow(try signOnly.sign(privateKey:Data(repeating:7,count:32),review:review(signOnly)))
        XCTAssertThrowsError(try request("sui_signAndExecuteTransaction",value:raw.base64EncodedString()))
    }
    func testBoundedMessagesAndCanonicalTransactionEncoding() throws {
        XCTAssertNoThrow(try request("sui_signPersonalMessage",value:String(repeating:"x",count:8192)))
        XCTAssertThrowsError(try request("sui_signPersonalMessage",value:String(repeating:"x",count:8193)))
        XCTAssertThrowsError(try request("sui_signPersonalMessage",value:""))
        XCTAssertThrowsError(try request(value:bytes + "\n"))
        var raw = Data(base64Encoded:bytes)!
        raw[0] = 1
        XCTAssertThrowsError(try request(value:raw.base64EncodedString()))
    }
    func testRejectWrongOwnersTrailingDataAndEveryTruncation() throws {
        XCTAssertThrowsError(try request(account:"0x2"))
        let raw = Data(base64Encoded:bytes)!
        for end in 0..<raw.count {
            XCTAssertThrowsError(try request(value:raw.prefix(end).base64EncodedString()))
        }
        XCTAssertThrowsError(try request(value:(raw + Data([0])).base64EncodedString()))
        XCTAssertThrowsError(try request().sign(privateKey:Data(repeating:8,count:32),review:review(request())))
    }
    func testExpiredReviewAndChangedBytes() throws {
        let r = try request()
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:7,count:32),review:review(r,date:.now.addingTimeInterval(-121))))
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:7,count:32),review:nil))
        var raw = Data(base64Encoded:bytes)!; raw[raw.count-9] ^= 1
        let altered = try request(value:raw.base64EncodedString())
        XCTAssertThrowsError(try altered.sign(privateKey:Data(repeating:7,count:32),review:review(r)))
    }
    func testWrongNetworkUnknownFieldsAndDuplicateKeys() throws {
        XCTAssertThrowsError(try WalletConnectSuiRequest(method:"sui_signPersonalMessage",chain:"sui:unknown",account:account,params:Data("{}".utf8)))
        for json in ["{\"address\":\"\(account)\",\"message\":\"a\",\"message\":\"b\"}","{\"address\":\"\(account)\",\"message\":\"a\",\"extra\":1}"] {
            XCTAssertThrowsError(try WalletConnectSuiRequest(method:"sui_signPersonalMessage",chain:"sui:mainnet",account:account,params:Data(json.utf8)))
        }
        XCTAssertTrue(try request("sui_signAndExecuteTransaction").broadcasts)
    }
}
