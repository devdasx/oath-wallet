import XCTest
@testable import OathAnkr

private actor ClosureRPC: AnkrTransport {
    let sender: String
    let recipient = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    var root: [String:XrplJSON]
    var destination = true, tagRequired = false, objects: [XrplJSON] = []
    var marker: XrplJSON = .null, ledger: UInt32 = 500, reserve = "1", increment = "0.2", open = "10"
    var wrongLedger = false, code = "tesSUCCESS", corruptCredit = false
    var submissions = [XrplJSON](), transaction: XrplJSON?
    init(sender: String) {
        self.sender = sender
        root = ["Account":.string(sender),"Balance":.string("1000000"),"OwnerCount":.number("0"),"Sequence":.number("42"),"Flags":.number("0")]
    }
    func field(_ key: String, _ value: XrplJSON) { root[key] = value }
    func configure(destination: Bool = true, tag: Bool = false, objects: [XrplJSON] = [], marker: XrplJSON = .null,
                   ledger: UInt32 = 500, reserve: String = "1", increment: String = "0.2", open: String = "10",
                   wrongLedger: Bool = false, code: String = "tesSUCCESS", corruptCredit: Bool = false) {
        self.destination=destination;tagRequired=tag;self.objects=objects;self.marker=marker;self.ledger=ledger
        self.reserve=reserve;self.increment=increment;self.open=open;self.wrongLedger=wrongLedger;self.code=code;self.corruptCredit=corruptCredit
    }
    func response(_ value: XrplJSON) { transaction = value }
    static func meta(sender: String, recipient: String, balance: UInt64 = 1_000_000, credit: UInt64 = 800_000) -> XrplJSON {
        .object(["TransactionResult":.string("tesSUCCESS"),"AffectedNodes":.array([
            .object(["DeletedNode":.object(["LedgerEntryType":.string("AccountRoot"),"FinalFields":.object(["Account":.string(sender),"Balance":.string("0")]),"PreviousFields":.object(["Balance":.string(String(balance))])])]),
            .object(["ModifiedNode":.object(["LedgerEntryType":.string("AccountRoot"),"FinalFields":.object(["Account":.string(recipient),"Balance":.string(String(5_000_000+credit))]),"PreviousFields":.object(["Balance":.string("5000000")])])])
        ])])
    }
    func send(_ request: URLRequest) async throws -> (Data,Int) {
        let body = try JSONDecoder().decode(XrplJSON.self,from:request.httpBody!), method = body["method"].string!, p = body["params"].array![0]
        var r: [String:XrplJSON] = ["status":.string("success")]
        switch method {
        case "server_info":
            r["info"] = .object(["network_id":.number("1"),"validated_ledger":.object(["age":.number("1"),"seq":.number(String(ledger)),"hash":.string(String(repeating:"A",count:64)),"reserve_base_xrp":.number(reserve),"reserve_inc_xrp":.number(increment)])])
        case "fee": r["drops"] = .object(["minimum_fee":.string("10"),"open_ledger_fee":.string(open)])
        case "account_info":
            if p["account"].string == recipient, !destination { r=["status":.string("error"),"error":.string("actNotFound")]; break }
            r["validated"] = .bool(true);r["ledger_hash"] = p["ledger_hash"]
            r["account_data"] = p["account"].string == sender ? .object(root) : .object(["Account":.string(recipient),"Balance":.string("5000000"),"Flags":.number(tagRequired ? "131072":"0")])
        case "account_objects":
            r["validated"] = .bool(true);r["ledger_hash"] = wrongLedger ? .string(String(repeating:"B",count:64)):p["ledger_hash"]
            r["account"] = .string(sender);r["account_objects"] = .array(objects);r["marker"] = marker
        case "simulate":
            let tx = p["tx_json"], fee = UInt64(tx["Fee"].text!)!, balance = UInt64(root["Balance"]!.text!)!
            r["tx_json"] = tx;r["engine_result"] = .string(code)
            r["meta"] = Self.meta(sender:sender,recipient:recipient,balance:balance,credit:balance-fee+(corruptCredit ? 1:0))
        case "tx":
            if case .object(let tx) = transaction { r = tx }
            else { r=["status":.string("error"),"error":.string("txnNotFound"),"searched_all":.bool(true)] }
        case "submit":
            submissions.append(p)
            let bytes = try TronIdentity.hex(p["tx_blob"].string!)
            r["accepted"] = .bool(true);r["engine_result"] = .string("tesSUCCESS");r["tx_blob"] = p["tx_blob"]
            r["tx_json"] = .object(["hash":.string(XrplSendCrypto.transactionHash(bytes))])
        default: throw XrplSendError.malformed
        }
        return (try JSONEncoder().encode(XrplJSON.object(["result":.object(r)])),200)
    }
}

final class XrplAccountClosureTests: XCTestCase {
    let key = Data(repeating:7,count:32), recipient = "rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    private func fixture() throws -> (String,ClosureRPC,XrplSendClient) {
        let sender = try XrplSendCrypto.address(privateKey:key), transport = ClosureRPC(sender:sender)
        return (sender,transport,try XrplSendClient(network:.testnet,transport:transport))
    }
    func testIndependentSDKBytesAndSignatureAndCannotBecomePayment() throws {
        struct Vector: Decodable { let testOnlyKey:String,address:String,bytes:String,hash:String }
        let url = Bundle.module.url(forResource:"closure-sdk-vector",withExtension:"json",subdirectory:"Fixtures/XrplSend")!
        let f = try JSONDecoder().decode(Vector.self,from:Data(contentsOf:url))
        let plan = XrplSendPlan(network:.testnet,sender:f.address,recipient:recipient,reference:"native",destinationTag:0,
            requestedAmount:"1000000",amount:"800000",assetDebit:"800000",assetBalance:"1000000",nativeBalance:1_000_000,
            reserve:1_000_000,fee:200_000,sequence:42,firstLedger:500,lastLedger:520,recipientReserve:0,accountDeletionFee:200_000)
        let signed = try XrplSendCrypto.sign(plan,privateKey:TronIdentity.hex(f.testOnlyKey))
        XCTAssertEqual(XrplSendCrypto.hex(signed.bytes),f.bytes);XCTAssertEqual(signed.hash,f.hash)
        XCTAssertEqual(plan.remaining,"0");XCTAssertEqual(plan.tokenFee,"0")
        let json = try plan.transactionJSON()
        XCTAssertEqual(json["TransactionType"].string,"AccountDelete");XCTAssertTrue(json["Amount"].isNull);XCTAssertTrue(json["SendMax"].isNull)
        XCTAssertEqual(try JSONDecoder().decode(XrplSendPlan.self,from:JSONEncoder().encode(plan)),plan)
        var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
        old.removeValue(forKey:"accountDeletionFee")
        let payment = try JSONDecoder().decode(XrplSendPlan.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertFalse(payment.closesAccount);XCTAssertThrowsError(try payment.validate())
        XCTAssertThrowsError(try XrplSendCrypto.verify(signed,plan:payment))
    }
    func testMalformedClosureCannotSignOrRelaxPaymentLimits() async throws {
        let (sender,_,c) = try fixture(), plan = try await c.quoteAccountClosure(sender:sender,recipient:recipient)
        let original = try JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as! [String:Any]
        for (field,value) in [("nativeBalance",1_000_001 as Any),("reserve",0),("fee",500_001),
                              ("accountDeletionFee",1),("amount","1000000"),("reference","OAT."+recipient),
                              ("recipientReserve",1_000_000),("firstLedger",298)] {
            var changed = original;changed[field] = value
            let invalid = try JSONDecoder().decode(XrplSendPlan.self,from:JSONSerialization.data(withJSONObject:changed))
            XCTAssertThrowsError(try XrplSendCrypto.sign(invalid,privateKey:key),field)
        }
        XCTAssertThrowsError(try plan.validate(now:plan.createdAt.addingTimeInterval(91)))
        try plan.validate(now:plan.createdAt.addingTimeInterval(91),checkAge:false)
    }
    func testQuoteUsesLiveFeeAndOnlyFinalOneXRP() async throws {
        let (sender,t,c) = try fixture()
        let plan = try await c.quoteAccountClosure(sender:sender,recipient:recipient)
        XCTAssertTrue(plan.closesAccount);XCTAssertEqual(plan.amount,"800000");XCTAssertEqual(plan.fee,200_000)
        await t.configure(increment:"0.3")
        let changed = try await c.quoteAccountClosure(sender:sender,recipient:recipient)
        XCTAssertEqual(changed.amount,"700000");XCTAssertEqual(changed.fee,300_000)
        for balance in ["999999","1000001","2000000"] {
            await t.field("Balance",.string(balance))
            do { _ = try await c.quoteAccountClosure(sender:sender,recipient:recipient);XCTFail("Not exactly reserve") }
            catch { XCTAssertEqual(error as? XrplSendError,.closureUnavailable) }
        }
        let writes = await t.submissions;XCTAssertTrue(writes.isEmpty)
    }
    func testObligationsAgeMalformedAndSponsorNeverOfferClosure() async throws {
        let variants: [(String,XrplJSON,XrplSendError)] = [
            ("OwnerCount",.number("1"),.closureObligations), ("MintedNFTokens",.number("1"),.closureObligations),
            ("Sponsor",.string(recipient),.closureObligations), ("SponsoringOwnerCount",.number("0"),.closureObligations),
            ("SponsoringAccountCount",.number("1"),.closureObligations), ("Sequence",.number("244"),.closureTooSoon),
            ("FirstNFTokenSequence",.number("244"),.closureTooSoon), ("OwnerCount",.string("0"),.malformed),
            ("Flags",.number("1048576"),.unsupportedAccount)
        ]
        for (field,value,expected) in variants {
            let (sender,t,c) = try fixture();await t.field(field,value)
            do { _ = try await c.quoteAccountClosure(sender:sender,recipient:recipient);XCTFail(field) }
            catch { XCTAssertEqual(error as? XrplSendError,expected,field) }
            let writes = await t.submissions;XCTAssertTrue(writes.isEmpty)
        }
    }
    func testObjectsAndPaginationCannotMasqueradeAsEmpty() async throws {
        for marked in [false,true] {
            let (sender,t,c) = try fixture()
            await t.configure(objects:marked ? []:[.object(["LedgerEntryType":.string("RippleState")])],marker:marked ? .string("next"):.null)
            do { _ = try await c.quoteAccountClosure(sender:sender,recipient:recipient);XCTFail("Objects allowed") }
            catch { XCTAssertEqual(error as? XrplSendError,.closureObligations) }
        }
    }
    func testRecipientMustExistAndTagIsPreserved() async throws {
        let (sender,t,c) = try fixture();await t.configure(destination:false)
        do { _ = try await c.quoteAccountClosure(sender:sender,recipient:recipient);XCTFail("Missing recipient") }
        catch { XCTAssertEqual(error as? XrplSendError,.recipientUnfunded) }
        await t.configure(tag:true)
        do { _ = try await c.quoteAccountClosure(sender:sender,recipient:recipient);XCTFail("Missing tag") }
        catch { XCTAssertEqual(error as? XrplSendError,.destinationTag) }
        let plan = try await c.quoteAccountClosure(sender:sender,recipient:recipient,destinationTag:0)
        XCTAssertEqual(try plan.transactionJSON()["DestinationTag"],.number("0"))
        do { _ = try await c.quoteAccountClosure(sender:sender,recipient:sender);XCTFail("Self") }
        catch { XCTAssertEqual(error as? XrplSendError,.sameRecipient) }
    }
    func testSimulationAndPinnedLedgerCannotBeBypassed() async throws {
        for variant in 0..<4 {
            let (sender,t,c) = try fixture()
            await t.configure(open:variant == 0 ? "300000":"10",wrongLedger:variant == 1,code:variant == 2 ? "tecNO_PERMISSION":"tesSUCCESS",corruptCredit:variant == 3)
            do { _ = try await c.quoteAccountClosure(sender:sender,recipient:recipient);XCTFail("Unsafe quote") }
            catch { XCTAssertTrue(error is XrplSendError) }
            let writes = await t.submissions;XCTAssertTrue(writes.isEmpty)
        }
    }
    func testSubmitRechecksAndUsesFailHardWithIdenticalBytes() async throws {
        let (sender,t,c) = try fixture()
        let p = try await c.quoteAccountClosure(sender:sender,recipient:recipient), signed = try XrplSendCrypto.sign(p,privateKey:key)
        let receipt = try await c.submit(signed,plan:p,reconcileFirst:false)
        XCTAssertEqual(receipt.outcome,.accepted)
        var writes = await t.submissions;XCTAssertEqual(writes.count,1);XCTAssertEqual(writes[0]["fail_hard"],.bool(true))
        XCTAssertEqual(writes[0]["tx_blob"].string,XrplSendCrypto.hex(signed.bytes))
        await t.field("Balance",.string("1000001"))
        do { try await c.revalidateAccountClosure(p);XCTFail("Stale consent") } catch { XCTAssertEqual(error as? XrplSendError,.closureUnavailable) }
        let stopped = try await c.submit(signed,plan:p)
        XCTAssertEqual(stopped.outcome,.unknown)
        writes = await t.submissions;XCTAssertEqual(writes.count,1,"Never submit changed balance")
    }
    func testFinalityRequiresDeletedAccountAndExactRecipientCredit() async throws {
        let (sender,t,c) = try fixture(), p = try await c.quoteAccountClosure(sender:sender,recipient:recipient)
        let signed = try XrplSendCrypto.sign(p,privateKey:key)
        var tx: [String:XrplJSON] = ["status":.string("success"),"hash":.string(signed.hash),"validated":.bool(false),"ledger_index":.number("501"),"tx_json":try p.transactionJSON(),"meta":ClosureRPC.meta(sender:sender,recipient:recipient)]
        await t.response(.object(tx))
        let pending = try await c.status(signed,plan:p);XCTAssertEqual(pending.outcome,.unknown)
        tx["validated"] = .bool(true);await t.response(.object(tx))
        let confirmed = try await c.status(signed,plan:p);XCTAssertEqual(confirmed.outcome,.confirmed);XCTAssertEqual(confirmed.deliveredAmount,"800000")
        // XRP arriving after submission is swept by protocol, and history must
        // use validated actual delivery, not the earlier estimated amount.
        tx["meta"] = ClosureRPC.meta(sender:sender,recipient:recipient,balance:1_100_000,credit:900_000);await t.response(.object(tx))
        let extra = try await c.status(signed,plan:p);XCTAssertEqual(extra.deliveredAmount,"900000")
        tx["meta"] = ClosureRPC.meta(sender:sender,recipient:recipient,credit:800_001);await t.response(.object(tx))
        do { _ = try await c.status(signed,plan:p);XCTFail("Corrupt credit") } catch { XCTAssertEqual(error as? XrplSendError,.changed) }
        tx["meta"] = .object(["TransactionResult":.string("tecHAS_OBLIGATIONS")]);await t.response(.object(tx))
        let failed = try await c.status(signed,plan:p);XCTAssertEqual(failed.outcome,.failed);XCTAssertEqual(failed.fee,200_000)
        XCTAssertNil(failed.deliveredAmount)
    }
}
