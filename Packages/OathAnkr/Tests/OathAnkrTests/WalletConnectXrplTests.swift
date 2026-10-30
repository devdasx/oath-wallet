import XCTest
@testable import OathAnkr

final class WalletConnectXrplTests: XCTestCase {
    let key = Data(repeating: 7, count: 32)
    var owner: String { try! XrplSendCrypto.address(privateKey: key) }
    var destination: String { try! XrplSendCrypto.address(privateKey: Data(repeating: 8, count: 32)) }
    func tx() -> [String:XrplJSON] { ["TransactionType": .string("Payment"), "Account": .string(owner), "Destination": .string(destination), "Amount": .string("1000000"), "Fee": .string("12"), "Sequence": .number("42"), "LastLedgerSequence": .number("120")] }
    func request(_ tx: [String:XrplJSON]? = nil, extra: [String:XrplJSON] = [:], method: String = "xrpl_signTransaction", chain: String = "xrpl:1") throws -> WalletConnectXrplRequest {
        var params = extra; params["tx_json"] = .object(tx ?? self.tx())
        return try .init(method: method, chain: chain, account: owner, params: JSONEncoder().encode(XrplJSON.object(params)))
    }
    func review(_ r: WalletConnectXrplRequest) -> WalletConnectXrplReview { .init(request:r,transaction:r.transaction,firstLedger:100,createdAt:.now) }
    func testNativeSigningAndResponse() throws {
        let r = try request(), plan = review(r), signed = try r.sign(privateKey:key,review:plan)
        XCTAssertTrue(r.broadcasts); XCTAssertTrue(r.autofill)
        try r.verify(signed,review:plan)
        XCTAssertEqual(signed.response["tx_json"]["hash"].string,signed.hash)
        XCTAssertThrowsError(try r.sign(privateKey:Data(repeating:8,count:32),review:plan))
    }
    func testRejectsUnknownFieldsAndDuplicateJSON() throws {
        var t=tx();t["HiddenAmount"] = .string("2")
        XCTAssertThrowsError(try request(t))
        XCTAssertThrowsError(try WalletConnectXrplRequest(method:"xrpl_signTransaction",chain:"xrpl:1",account:owner,params:Data("{\"tx_json\":{},\"tx_json\":{}}".utf8)))
    }
    func testWrongOwnerNetworkAndBoolean() throws {
        var t=tx();t["Account"] = .string(destination);XCTAssertThrowsError(try request(t))
        t=tx();t["NetworkID"] = .number("1");XCTAssertThrowsError(try request(t))
        XCTAssertThrowsError(try request(chain:"xrpl:2"))
        XCTAssertThrowsError(try request(extra:["submit":.string("false")]))
    }
    func testChangedReviewAndExcessiveFee() throws {
        let r=try request();var t=tx();t["Amount"] = .string("2000000")
        let changed=WalletConnectXrplReview(request:r,transaction:.object(t),firstLedger:100,createdAt:.now)
        XCTAssertThrowsError(try r.sign(privateKey:key,review:changed))
        t=tx();t["Fee"] = .string("100001");let fee=try request(t)
        XCTAssertThrowsError(try review(fee).validate())
        let stale=WalletConnectXrplReview(request:r,transaction:r.transaction,firstLedger:100,createdAt:Date(timeIntervalSinceNow:-121))
        XCTAssertThrowsError(try r.sign(privateKey:key,review:stale))
    }
    func testPartialMultisignAndDefaults() throws {
        var t=tx();t["Account"] = .string(destination);t["SigningPubKey"] = .string("")
        let r=try request(t,extra:["tx_signer":.string(owner)],method:"xrpl_signTransactionFor")
        XCTAssertFalse(r.autofill);XCTAssertFalse(r.broadcasts)
        let signed=try r.sign(privateKey:key,review:review(r))
        XCTAssertEqual(signed.transaction["Signers"].array?.count,1)
        try r.verify(signed,review:review(r))
    }
    func testPreservesPriorMultisignatureAndRejectsTampering() throws {
        var t=tx();t["Account"] = .string(destination);t["SigningPubKey"] = .string("")
        let first=try request(t,extra:["tx_signer":.string(owner)],method:"xrpl_signTransactionFor")
        let partial=try first.sign(privateKey:key,review:review(first))
        let secondKey=Data(repeating:9,count:32), secondOwner=try XrplSendCrypto.address(privateKey:secondKey)
        let params=XrplJSON.object(["tx_json":partial.transaction,"tx_signer":.string(secondOwner)])
        let second=try WalletConnectXrplRequest(method:"xrpl_signTransactionFor",chain:"xrpl:1",account:secondOwner,params:JSONEncoder().encode(params))
        let signed=try second.sign(privateKey:secondKey,review:review(second))
        XCTAssertEqual(signed.transaction["Signers"].array?.count,2)
        try second.verify(signed,review:review(second))
        var changed=partial.transaction.fields!;changed["Amount"] = .string("2000000")
        XCTAssertThrowsError(try WalletConnectXrplRequest(method:"xrpl_signTransactionFor",chain:"xrpl:1",account:secondOwner,params:JSONEncoder().encode(XrplJSON.object(["tx_json":.object(changed),"tx_signer":.string(secondOwner)]))))
        XCTAssertThrowsError(try request(partial.transaction.fields,extra:["tx_signer":.string(owner)],method:"xrpl_signTransactionFor"))
    }
    func testNoAutofillRequiresExplicitExpiryAndFee() throws {
        for field in ["Fee","Sequence","LastLedgerSequence"] {
            var t=tx();t.removeValue(forKey:field)
            let r=try request(t,extra:["autofill":.bool(false)])
            XCTAssertThrowsError(try review(r).validate())
        }
    }
    func testTokenTagMemoAndOffer() throws {
        var t=tx();t["Amount"] = .object(["currency":.string("USD"),"issuer":.string(destination),"value":.string("2.5")]);t["DestinationTag"] = .number("0")
        t["Memos"] = .array([.object(["Memo":.object(["MemoData":.string("74657374")])])])
        let r=try request(t);try r.verify(r.sign(privateKey:key,review:review(r)),review:review(r))
        t=tx();t.removeValue(forKey:"Amount");t.removeValue(forKey:"Destination");t["TransactionType"] = .string("OfferCreate")
        t["TakerPays"] = .string("1000000");t["TakerGets"] = .object(["currency":.string("USD"),"issuer":.string(destination),"value":.string("1")])
        let offer=try request(t);try offer.verify(offer.sign(privateKey:key,review:review(offer)),review:review(offer))
    }
}
