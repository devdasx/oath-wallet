import XCTest
@testable import OathAnkr

final class XrplSendTests: XCTestCase {
    func testOfficialSDKPaymentBytesAndSignatures() throws {
        struct Vector: Decodable { let reference:String,amount:String,bytes:String,hash:String }
        struct Fixture: Decodable { let testOnlyKey:String,address:String,publicKey:String,vectors:[Vector] }
        let url = Bundle.module.url(forResource:"sdk-vector",withExtension:"json",subdirectory:"Fixtures/XrplSend")!
        let fixture = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url))
        let key = try TronIdentity.hex(fixture.testOnlyKey)
        XCTAssertEqual(try XrplSendCrypto.address(privateKey:key),fixture.address)
        XCTAssertEqual(try XrplSendCrypto.hex(XrplSendCrypto.publicKey(privateKey:key)),fixture.publicKey)
        for vector in fixture.vectors {
            let plan = XrplSendPlan(network:.testnet,sender:fixture.address,recipient:"rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh",reference:vector.reference,
                destinationTag:0,requestedAmount:vector.amount,amount:vector.amount,assetDebit:vector.amount,assetBalance:vector.reference == "native" ? "10000000":vector.amount,
                nativeBalance:10_000_000,reserve:1_000_000,fee:12,sequence:42,firstLedger:100,lastLedger:120)
            let signed = try XrplSendCrypto.sign(plan,privateKey:key)
            XCTAssertEqual(XrplSendCrypto.hex(signed.bytes),vector.bytes)
            XCTAssertEqual(signed.hash,vector.hash)
            XCTAssertNoThrow(try XrplSendCrypto.verify(signed,plan:plan))
            let altered = XrplSignedSend(bytes:signed.bytes+Data([0]),publicKey:signed.publicKey,signature:signed.signature,hash:signed.hash)
            XCTAssertThrowsError(try XrplSendCrypto.verify(altered,plan:plan))
            XCTAssertThrowsError(try XrplSendCrypto.sign(plan,privateKey:Data(repeating:8,count:32)))
            XCTAssertThrowsError(try plan.validate(now:plan.createdAt.addingTimeInterval(91)))
        }
    }
    func testRIPEMDAndIssuedPrecision() throws {
        XCTAssertEqual(XrplSendCrypto.hex(XrplRIPEMD160.hash(Data())),"9C1185A5C5E9FC54612808977EE8F548B2258D31")
        XCTAssertEqual(XrplSendCrypto.hex(XrplRIPEMD160.hash(Data("abc".utf8))),"8EB208F7E05D987A9B044A8E98C6B087F15A0BFC")
        for value in ["1", "12345.67890123456", "1e-81", "9.999999999999999e95"] {
            let atomic = try XrplIdentity.issuedAmount(value)
            XCTAssertEqual(try XrplIdentity.issuedAmount(XrplSendAmount.issuedValue(atomic)),atomic)
        }
        XCTAssertEqual(try XrplSendAmount.ratio("100",numerator:101,denominator:100,up:true),"101")
        XCTAssertEqual(try XrplSendAmount.ratio("100",numerator:100,denominator:101,up:false),"99")
        XCTAssertThrowsError(try XrplSendAmount.issuedValue("12345678901234567"))
    }
    struct LiveFixture: Decodable {
        struct Wallet: Decodable { let address:String,privateKey:String }
        let sender:Wallet,recipient:Wallet,issuer:Wallet
        let issued:String?,mpt:String?
    }
    private func rpc(_ method:String,_ params:[String:XrplJSON]) async throws -> XrplJSON {
        var request = URLRequest(url:XrplSendNetwork.testnet.endpoint);request.httpMethod="POST";request.timeoutInterval=20
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        var p=params;p["api_version"] = .number("2")
        request.httpBody=try JSONEncoder().encode(XrplJSON.object(["method":.string(method),"params":.array([.object(p)])]))
        let (data,_) = try await URLSession.shared.data(for:request)
        return try JSONDecoder().decode(XrplJSON.self,from:data)["result"]
    }
    private func balance(_ owner:String,_ reference:String,at ledger:UInt32? = nil) async throws -> String {
        let index = ledger.map { XrplJSON.number(String($0)) } ?? .string("validated")
        func read(_ method:String,_ params:[String:XrplJSON]) async throws -> XrplJSON {
            // Public testnet nodes can lag one another. Read the exact receipt
            // ledger, never mistake an older "validated" balance for delivery.
            for attempt in 0..<6 {
                let result = try await rpc(method,params.merging(["ledger_index":index]) { _,new in new })
                if ledger != nil, ["lgrNotFound","ledgerNotFound"].contains(result["error"].string), attempt < 5 {
                    try await Task.sleep(for:.seconds(1));continue
                }
                XCTAssertEqual(result["status"].string,"success")
                XCTAssertEqual(result["validated"],.bool(true))
                if let ledger { XCTAssertEqual(result["ledger_index"].integer,UInt64(ledger)) }
                return result
            }
            throw XrplSendError.changed
        }
        if reference == "native" {
            let result=try await read("account_info",["account":.string(owner)])
            return try XCTUnwrap(result["account_data"]["Balance"].string)
        }
        if let dot=reference.lastIndex(of:".") {
            let r=try await read("account_lines",["account":.string(owner),"peer":.string(String(reference[reference.index(after:dot)...]))])
            let row=try XCTUnwrap(r["lines"].array?.first(where:{$0["currency"].string == String(reference[..<dot])}))
            return try XrplIdentity.issuedAmount(XCTUnwrap(row["balance"].string))
        }
        return try await read("ledger_entry",["mptoken":.object(["account":.string(owner),"mpt_issuance_id":.string(reference)])])["node"]["MPTAmount"].string ?? "0"
    }
    /// Opt-in TESTNET only. Independent fixture creation; production Swift
    /// preparation, serialization, signatures, RPC, delivery and exact-byte retry.
    func testLiveTestnetNativeIssuedAndMPT() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_XRPL_TESTNET_FIXTURE"] else { throw XCTSkip("Explicit Testnet fixture required") }
        let f=try JSONDecoder().decode(LiveFixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        var key=try TronIdentity.hex(String(f.sender.privateKey.suffix(64)));defer{key.resetBytes(in:0..<key.count)}
        XCTAssertEqual(try XrplSendCrypto.address(privateKey:key),f.sender.address)
        let client=try XrplSendClient(network:.testnet)
        let refs=["native",try XCTUnwrap(f.issued),try XCTUnwrap(f.mpt)]
        for reference in refs {
            let amount=reference == "native" ? "123456" : reference.contains(".") ? try XrplIdentity.issuedAmount("1.23456789") : "123"
            let plan=try await client.quote(sender:f.sender.address,recipient:f.recipient.address,reference:reference,amount:amount,destinationTag:0)
            let before=try await balance(f.recipient.address,reference,at:plan.firstLedger)
            let senderBefore=try await balance(f.sender.address,reference,at:plan.firstLedger)
            XCTAssertGreaterThan(plan.fee,0);XCTAssertLessThanOrEqual(plan.fee,100000)
            let signed=try XrplSendCrypto.sign(plan,privateKey:key)
            var receipt=try await client.submit(signed,plan:plan)
            for _ in 0..<20 where receipt.outcome == .unknown || receipt.outcome == .accepted {try await Task.sleep(for:.seconds(1));receipt=try await client.status(signed,plan:plan)}
            XCTAssertEqual(receipt.outcome,.confirmed)
            let ledger=try XCTUnwrap(receipt.ledger)
            let after=try await balance(f.recipient.address,reference,at:ledger)
            XCTAssertEqual(after,SuiIdentity.add(before,amount))
            let senderAfter=try await balance(f.sender.address,reference,at:ledger)
            let debit=reference == "native" ? SuiIdentity.add(plan.assetDebit,String(plan.fee)):plan.assetDebit
            XCTAssertEqual(senderAfter,SuiIdentity.add(senderBefore,"-"+debit))
            let retry=try await client.submit(signed,plan:plan)
            XCTAssertEqual(retry.outcome,.confirmed)
            let retriedBalance=try await balance(f.recipient.address,reference,at:ledger)
            XCTAssertEqual(retriedBalance,after)
            guard receipt.outcome == .confirmed, retry.outcome == .confirmed,
                  after == SuiIdentity.add(before,amount), senderAfter == SuiIdentity.add(senderBefore,"-"+debit), retriedBalance == after else { return }
            print("XRPL_TESTNET_CONFIRMED type=\(reference == "native" ? "XRP":reference.contains(".") ? "issued":"MPT") hash=\(signed.hash) fee=\(plan.fee) exact_delivery=true retry_idempotent=true")
        }
    }
    func testLiveTestnetTagsUnfundedReserveAndMaximum() async throws {
        guard let path=ProcessInfo.processInfo.environment["OATH_XRPL_TESTNET_FIXTURE"] else { throw XCTSkip("Explicit Testnet fixture required") }
        let f=try JSONDecoder().decode(LiveFixture.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        var key=try TronIdentity.hex(String(f.sender.privateKey.suffix(64))), recipientKey=try TronIdentity.hex(String(f.recipient.privateKey.suffix(64)))
        var temporary=Data((0..<32).map{_ in UInt8.random(in:1...254)})
        defer {key.resetBytes(in:0..<key.count);recipientKey.resetBytes(in:0..<recipientKey.count);temporary.resetBytes(in:0..<temporary.count)}
        let client=try XrplSendClient(network:.testnet), owner=try XrplSendCrypto.address(privateKey:temporary)
        do { _ = try await client.quote(sender:f.sender.address,recipient:f.recipient.address,reference:"native",amount:"100000");XCTFail("Required destination tag omitted") }
        catch { XCTAssertEqual(error as? XrplSendError,.destinationTag) }
        do { _ = try await client.quote(sender:f.sender.address,recipient:owner,reference:"native",amount:"1");XCTFail("Unfunded destination reserve omitted") }
        catch { XCTAssertEqual(error as? XrplSendError,.recipientUnfunded) }
        let funding=try await client.quote(sender:f.sender.address,recipient:owner,reference:"native",amount:"3000000")
        let funded=try await client.submit(XrplSendCrypto.sign(funding,privateKey:key),plan:funding)
        XCTAssertEqual(funded.outcome,.confirmed)
        do { _ = try await client.quote(sender:f.sender.address,recipient:owner,reference:XCTUnwrap(f.issued),amount:XrplIdentity.issuedAmount("1"));XCTFail("Missing trust line accepted") }
        catch { guard case .simulation = error as? XrplSendError else { return XCTFail("Expected ledger restriction") } }
        let maximum=try await client.quote(sender:owner,recipient:f.sender.address,reference:"native",amount:"3000000",maximum:true)
        XCTAssertEqual(UInt64(maximum.amount),3_000_000-maximum.reserve-maximum.fee)
        let signed=try XrplSendCrypto.sign(maximum,privateKey:temporary)
        let sent=try await client.submit(signed,plan:maximum)
        XCTAssertEqual(sent.outcome,.confirmed)
        let remaining=try await balance(owner,"native")
        XCTAssertEqual(remaining,String(maximum.reserve))
        print("XRPL_TESTNET_MAX_CONFIRMED type=XRP hash=\(signed.hash) reserve_preserved=true")
        for reference in [try XCTUnwrap(f.issued),try XCTUnwrap(f.mpt)] {
            let available=try await balance(f.recipient.address,reference)
            let before=try await balance(f.sender.address,reference)
            let plan=try await client.quote(sender:f.recipient.address,recipient:f.sender.address,reference:reference,amount:available,maximum:true)
            XCTAssertFalse(XrplSendAmount.less(available,plan.assetDebit))
            let signed=try XrplSendCrypto.sign(plan,privateKey:recipientKey)
            let receipt=try await client.submit(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            let after=try await balance(f.sender.address,reference), left=try await balance(f.recipient.address,reference)
            let added = SuiIdentity.add(before,plan.amount)
            // Classic trust-line balances themselves have 16 significant digits.
            // Delivery is checked exactly from validated metadata by the client;
            // a large existing balance rounds the resulting sum on the ledger.
            let rounded = reference.contains(".") && added.count > 16
                ? try XrplSendAmount.roundedIssued(added,up:added[added.index(added.startIndex,offsetBy:16)] >= "5") : added
            XCTAssertEqual(after,rounded)
            XCTAssertEqual(left,plan.remaining)
            print("XRPL_TESTNET_MAX_CONFIRMED type=\(reference.contains(".") ? "issued":"MPT") hash=\(signed.hash) exact_delivery=true")
        }
    }

}
