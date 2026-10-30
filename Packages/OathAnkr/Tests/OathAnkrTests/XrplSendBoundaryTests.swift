import XCTest
@testable import OathAnkr

actor XrplRPCFixture: AnkrTransport {
    let sender:String,recipient:String
    var balance:UInt64 = 10_000_000, tagRequired=false, network:UInt64=1, height:UInt32=100, searchedAll=false
    var txResult: XrplJSON?, errorCode: String?
    var engine="tesSUCCESS", methods=[String](), submitted=[Data](), unavailable=false
    var networkField: XrplJSON?, omitAnkrNetworkID=false
    var primaryUnavailable = false
    func failPrimary() { primaryUnavailable = true }
    var missingRecipient = false, baseReserve = "1"
    func activation(_ reserve: String) { missingRecipient = true; baseReserve = reserve }
    var calls=[String]()
    var signerList: XrplJSON = .null, ownerFlags: UInt64 = 0, regularKey: String?
    func multisig(list: XrplJSON, disabled: Bool, regular: String? = nil) { signerList=list;ownerFlags=disabled ? 0x100000:0;regularKey=regular }

    var acknowledgement:XrplJSON = .null
    func ack(_ value:XrplJSON) { acknowledgement=value }
    init(sender:String,recipient:String) { self.sender=sender;self.recipient=recipient }
    func configure(balance:UInt64?=nil,tag:Bool?=nil,network:UInt64?=nil,height:UInt32?=nil,searchedAll:Bool?=nil,engine:String?=nil,unavailable:Bool?=nil) {
        if let balance{self.balance=balance};if let tag{tagRequired=tag};if let network{self.network=network};if let height{self.height=height}
        if let searchedAll{self.searchedAll=searchedAll};if let engine{self.engine=engine};if let unavailable{self.unavailable=unavailable}
    }
    func response(_ tx: XrplJSON) { txResult = tx }
    func fail(_ code: String) { errorCode = code }
    func networkResponse(_ field: XrplJSON? = nil, omitAnkr: Bool = false) {
        networkField=field; omitAnkrNetworkID=omitAnkr
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let body=try JSONDecoder().decode(XrplJSON.self,from:request.httpBody!),method=body["method"].string!,p=body["params"].array![0]
        methods.append(method)
        calls.append((request.url?.host ?? "")+":"+method)
        if primaryUnavailable && request.url?.host == "xrplcluster.com" { return (Data(),503) }
        if let errorCode { return (try JSONEncoder().encode(XrplJSON.object(["result":.object(["status":.string("error"),"error":.string(errorCode),"error_message":.string("PRIVATE_RESPONSE_MARKER"),"request":body])])),200) }
        var r:[String:XrplJSON]=["status":.string("success")]
        switch method {
        case "server_info":
            var info:[String:XrplJSON] = ["network_id":networkField ?? .number(String(network)),"validated_ledger":.object(["age":.number("1"),"seq":.number(String(height)),"hash":.string(String(repeating:"A",count:64)),"reserve_base_xrp":.number(baseReserve),"reserve_inc_xrp":.number("0.2")])]
            if omitAnkrNetworkID && request.url?.host == "rpc.ankr.com" { info.removeValue(forKey:"network_id") }
            r["info"] = .object(info)
        case "fee":r["drops"] = .object(["minimum_fee":.string("10"),"open_ledger_fee":.string("10")])
        case "account_info":r["validated"] = .bool(true);r["ledger_hash"] = p["ledger_hash"]
            let a=p["account"].string!
            if a == recipient, missingRecipient { r = ["status":.string("error"),"error":.string("actNotFound")]; break }
            r["account_data"] = .object(["Account":.string(a),"Balance":.string(String(balance)),"OwnerCount":.number("2"),"Sequence":.number("42"),"Flags":.number(a==sender ? String(ownerFlags) : a==recipient && tagRequired ? "131072":"0")])
            if a == sender, let regularKey, case .object(var root) = r["account_data"] { root["RegularKey"] = .string(regularKey);r["account_data"] = .object(root) }
        case "account_objects":
            r["validated"] = .bool(true);r["ledger_hash"] = p["ledger_hash"];r["account"] = p["account"]
            r["account_objects"] = .array(signerList.isNull ? []:[signerList])
        case "account_lines":
            r["validated"] = .bool(true); r["ledger_hash"] = p["ledger_hash"]; r["account"] = p["account"]
            r["lines"] = .array([.object(["account": p["peer"], "currency": .string("USD"), "balance": .string("10")])])
        case "simulate":
            let tx=p["tx_json"]
            if ["TrustSet","MPTokenAuthorize"].contains(tx["TransactionType"].string ?? "") {
                var result=tx
                if case .object(var fields)=tx, case .object(var limit)=tx["LimitAmount"] {
                    limit["value"] = .string("200000");fields["LimitAmount"] = .object(limit);result = .object(fields)
                }
                r["tx_json"]=result;r["engine_result"] = .string(engine);r["meta"] = .object(["TransactionResult":.string(engine)])
                break
            }
            let amount=tx["Amount"].string!,fee=UInt64(tx["Fee"].string!)!
            r["tx_json"]=tx;r["engine_result"] = .string(engine)
            r["meta"] = .object(["TransactionResult":.string(engine),"delivered_amount":.string(amount),"AffectedNodes":.array([.object(["ModifiedNode":.object(["LedgerEntryType":.string("AccountRoot"),"FinalFields":.object(["Account":.string(sender),"Balance":.string(String(balance-UInt64(amount)!-fee))]),"PreviousFields":.object(["Balance":.string(String(balance))])])])])])
        case "tx":if case .object(let value) = txResult { r=value;break };r=["status":.string("error"),"error":.string("txnNotFound"),"searched_all":.bool(searchedAll)]
        case "submit":submitted.append(request.httpBody!);if unavailable{throw URLError(.timedOut)};r["engine_result"] = .string("tesSUCCESS");if case .object(let ack)=acknowledgement { r.merge(ack){_,new in new} }
        default:throw XrplSendError.malformed
        }
        return (try JSONEncoder().encode(XrplJSON.object(["result":.object(r)])),200)
    }
}
final class XrplSendBoundaryTests:XCTestCase {
    let key=Data(repeating:7,count:32), recipient="rHb9CJAWyB4rj91VRWn96DkukG4bwdtyTh"
    func testNewRecipientUsesLedgerMinimumAndAcceptsExactFunding() async throws {
        for (reserve,minimum) in [("1",UInt64(1_000_000)),("2",2_000_000)] {
            let sender=try XrplSendCrypto.address(privateKey:key),t=XrplRPCFixture(sender:sender,recipient:recipient)
            await t.activation(reserve)
            let c=try XrplSendClient(network:.testnet,transport:t)
            do { _ = try await c.quote(sender:sender,recipient:recipient,reference:"native",amount:String(minimum-1));XCTFail("Underfunded account accepted") }
            catch { XCTAssertEqual(error as? XrplSendError,.recipientMinimum(minimum)) }
            let plan=try await c.quote(sender:sender,recipient:recipient,reference:"native",amount:String(minimum))
            XCTAssertEqual(plan.amount,String(minimum))
            XCTAssertEqual(plan.accountCost?.atomic,String(minimum));XCTAssertEqual(plan.accountCost?.inclusion,.payment)
            let legacy=try withoutAccountCostMetadata(plan)
            XCTAssertNil(legacy.accountCost)
            XCTAssertEqual(try legacy.transactionJSON(),try plan.transactionJSON())
            XCTAssertEqual(plan.assetDebit,plan.amount,"Recipient reserve must not increase debit")
            let writes=await t.submitted;XCTAssertTrue(writes.isEmpty)
        }
    }
    func testFreshAcknowledgementDoesNotWaitForValidatedLedger() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),t=XrplRPCFixture(sender:sender,recipient:recipient),c=try XrplSendClient(network:.testnet,transport:t)
        let p=try await c.quote(sender:sender,recipient:recipient,reference:"native",amount:"100"),s=try XrplSendCrypto.sign(p,privateKey:key)
        XCTAssertNil(p.accountCost,"Existing XRP recipient must not show another reserve")
        let before=await t.methods.count
        for code in ["tesSUCCESS","terQUEUED"] {
            await t.ack(.object(["accepted":.bool(true),"engine_result":.string(code),"tx_blob":.string(XrplSendCrypto.hex(s.bytes)),"tx_json":.object(["hash":.string(s.hash)])]))
            let receipt=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(receipt.outcome,.accepted);XCTAssertNil(receipt.ledger)
        }
        let calls=await t.methods;XCTAssertEqual(Array(calls.dropFirst(before)),["submit","submit"])
        await t.ack(.object(["accepted":.bool(false),"engine_result":.string("tesSUCCESS")]))
        let notAccepted=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(notAccepted.outcome,.unknown)
        await t.ack(.object(["accepted":.bool(true),"tx_blob":.string(XrplSendCrypto.hex(s.bytes)),"tx_json":.object(["hash":.string("wrong")])]))
        let wrong=try await c.submit(s,plan:p,reconcileFirst:false);XCTAssertEqual(wrong.outcome,.unknown)
    }
    func testCompatibleProviderAvoidsRepeatedMissingNetworkIDForQuoteAndReconciliation() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        await transport.configure(network:0)
        await transport.networkResponse(omitAnkr:true)
        let client=try XrplSendClient(network:.mainnet,apiKey:"testOnlyCredential",transport:transport)
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"730433")
        XCTAssertEqual(plan.network,.mainnet);XCTAssertEqual(plan.amount,"730433");XCTAssertEqual(plan.fee,12)
        let signed=try XrplSendCrypto.sign(plan,privateKey:key)
        await transport.response(.object(["status":.string("success"),"hash":.string(signed.hash),"validated":.bool(true),"ledger_index":.number("101"),
            "tx_json":try plan.transactionJSON(),"meta":.object(["TransactionResult":.string("tesSUCCESS"),"delivered_amount":.string(plan.amount)])]))
        let reconciled=try await client.status(signed,plan:plan)
        let retried=try await client.submit(signed,plan:plan)
        XCTAssertEqual(reconciled.outcome,.confirmed);XCTAssertEqual(retried.outcome,.confirmed)
        let calls=await transport.calls, writes=await transport.submitted
        XCTAssertFalse(calls.contains("rpc.ankr.com:server_info"))
        XCTAssertTrue(calls.contains("xrplcluster.com:simulate"))
        XCTAssertTrue(calls.contains("xrplcluster.com:tx"))
        XCTAssertFalse(calls.contains("rpc.ankr.com:account_info"))
        XCTAssertFalse(calls.contains("rpc.ankr.com:simulate"))
        XCTAssertFalse(calls.contains("rpc.ankr.com:tx"))
        XCTAssertTrue(writes.isEmpty)
    }
    func testConfiguredProviderRemainsFallbackOnlyWithVerifiedNetworkIdentity() async throws {
        for omitNetwork in [false,true] {
            let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
            await transport.configure(network:0)
            await transport.failPrimary()
            await transport.networkResponse(omitAnkr:omitNetwork)
            let client=try XrplSendClient(network:.mainnet,apiKey:"testOnlyCredential",transport:transport)
            do {
                let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"730433")
                XCTAssertFalse(omitNetwork,"Unverified fallback accepted")
                XCTAssertEqual(plan.network,.mainnet)
            } catch {
                XCTAssertTrue(omitNetwork)
                XCTAssertEqual(error as? XrplSendError,.malformed)
            }
            let calls=await transport.calls
            XCTAssertTrue(calls.contains("xrplcluster.com:server_info"))
            XCTAssertTrue(calls.contains("rpc.ankr.com:server_info"))
            XCTAssertEqual(calls.contains("rpc.ankr.com:simulate"),!omitNetwork)
        }
    }
    func testMissingOrMalformedNetworkIDNeverAssumesMainnetOrTestnet() async throws {
        for network in [XrplSendNetwork.mainnet,.testnet] {
            for field in [XrplJSON.null,.string(String(network.id)),.bool(false),.number("-1")] {
                let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
                await transport.networkResponse(field)
                let client=try XrplSendClient(network:network,transport:transport)
                do { _ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100");XCTFail("Unverified network accepted") }
                catch { XCTAssertEqual(error as? XrplSendError,.malformed) }
                let calls=await transport.methods
                XCTAssertFalse(calls.contains("account_info"));XCTAssertFalse(calls.contains("simulate"));XCTAssertFalse(calls.contains("submit"))
            }
        }
    }
    func testExplicitWrongNetworkDoesNotFallBack() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.mainnet,apiKey:"testOnlyCredential",transport:transport)
        do { _ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100");XCTFail("Wrong network accepted") }
        catch { XCTAssertEqual(error as? XrplSendError,.wrongNetwork) }
        let calls=await transport.calls
        XCTAssertFalse(calls.contains(where:{$0.hasPrefix("rpc.ankr.com:")}))
        XCTAssertFalse(calls.contains(where:{$0.hasSuffix(":account_info") || $0.hasSuffix(":simulate")}))
    }
    func testStringFeeAndBalanceMaximumReservesOwnersAndFee() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport)
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"10000000",maximum:true)
        XCTAssertEqual(plan.fee,12);XCTAssertEqual(plan.reserve,1_400_000);XCTAssertEqual(plan.amount,"8599988");XCTAssertEqual(plan.remaining,"1400000")
        await transport.configure(balance:1_400_011)
        do{_ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"1");XCTFail("Insufficient fee funds accepted")}catch{XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance)}
        await transport.configure(balance:1_399_999)
        do{_ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"1");XCTFail("Reserve spent")}catch{XCTAssertEqual(error as? XrplSendError,.reserve)}
    }
    func testRequiredTagIncludesZeroAndUInt32Maximum() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport);await transport.configure(tag:true)
        do{_ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100");XCTFail("Tag omitted")}catch{XCTAssertEqual(error as? XrplSendError,.destinationTag)}
        for tag:UInt32 in [0,.max]{let p=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100",destinationTag:tag);XCTAssertEqual(p.destinationTag,tag)}
    }
    func testWrongNetworkAndTokenRestrictionNeverBroadcast() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport);await transport.configure(network:0)
        do{_ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100");XCTFail("Wrong network")}catch{XCTAssertEqual(error as? XrplSendError,.wrongNetwork)}
        await transport.configure(network:1,engine:"tecFROZEN")
        do{_ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100");XCTFail("Restriction ignored")}catch{XCTAssertEqual(error as? XrplSendError,.simulation("tecFROZEN"))}
        let writes=await transport.submitted;XCTAssertTrue(writes.isEmpty)
    }
    func testExpiryNeedsCompleteLedgerSearchAndNeverResubmitsExpiredBytes() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport)
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100")
        let signed=try XrplSendCrypto.sign(plan,privateKey:key)
        await transport.configure(height:121,searchedAll:false)
        let unknown=try await client.status(signed,plan:plan);XCTAssertEqual(unknown.outcome,.unknown)
        await transport.configure(searchedAll:true)
        let expired=try await client.submit(signed,plan:plan);XCTAssertEqual(expired.outcome,.expired)
        let writes=await transport.submitted;XCTAssertTrue(writes.isEmpty)
    }
    func testAmbiguousBroadcastKeepsExactBytesAndReturnsUnknown() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport)
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100")
        let signed=try XrplSendCrypto.sign(plan,privateKey:key);await transport.configure(unavailable:true)
        for _ in 0..<2 {let result=try await client.submit(signed,plan:plan);XCTAssertEqual(result.outcome,.unknown)}
        let writes=await transport.submitted;XCTAssertEqual(writes.count,2);XCTAssertEqual(try JSONDecoder().decode(XrplJSON.self,from:XCTUnwrap(writes.first)),try JSONDecoder().decode(XrplJSON.self,from:XCTUnwrap(writes.last)))
        let data=try JSONDecoder().decode(XrplJSON.self,from:XCTUnwrap(writes.first))
        XCTAssertEqual(data["params"].array?.first?["tx_blob"].string,XrplSendCrypto.hex(signed.bytes))
    }
    func testValidatedFailureAndWrongDeliveredAmountAreNeverSuccess() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport)
        let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100")
        let signed=try XrplSendCrypto.sign(plan,privateKey:key)
        var receipt:[String:XrplJSON]=["status":.string("success"),"hash":.string(signed.hash),"validated":.bool(true),"ledger_index":.number("101"),
            "tx_json":try plan.transactionJSON(),"meta":.object(["TransactionResult":.string("tecPATH_DRY")])]
        await transport.response(.object(receipt))
        let failure=try await client.status(signed,plan:plan);XCTAssertEqual(failure.outcome,.failed);XCTAssertEqual(failure.fee,12)
        receipt["meta"] = .object(["TransactionResult":.string("tecUNRECOGNIZED_PRIVATE_MARKER")])
        await transport.response(.object(receipt))
        let unfamiliar=try await client.status(signed,plan:plan)
        XCTAssertEqual(unfamiliar.outcome,.failed);XCTAssertEqual(unfamiliar.code,"tecUNKNOWN")
        receipt["meta"] = .object(["TransactionResult":.string("tesSUCCESS"),"delivered_amount":.string("99")])
        await transport.response(.object(receipt))
        do{_ = try await client.status(signed,plan:plan);XCTFail("Incorrect delivery accepted")}catch{XCTAssertEqual(error as? XrplSendError,.changed)}
    }
    func testProviderEnvelopeDropsUntrustedFieldsAndUnknownCodes() async throws {
        let sender=try XrplSendCrypto.address(privateKey:key),transport=XrplRPCFixture(sender:sender,recipient:recipient)
        let client=try XrplSendClient(network:.testnet,transport:transport)
        await transport.fail("PRIVATE_CREDENTIAL_MARKER")
        do{_ = try await client.quote(sender:sender,recipient:recipient,reference:"native",amount:"100");XCTFail("Provider error ignored")}
        catch{XCTAssertEqual(error as? XrplSendError,.rpc("UNKNOWN"));XCTAssertFalse(String(describing:error).contains("PRIVATE"))}
    }

}
