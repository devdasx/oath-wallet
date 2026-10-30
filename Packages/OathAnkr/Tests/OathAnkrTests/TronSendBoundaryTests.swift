import XCTest
@testable import OathAnkr

private actor TronSendTransportFixture:AnkrTransport {
    let sender:String,recipient:String
    var options:[String:TronJSON]=[:],requests:[URLRequest]=[],body:TronJSON = .object([:]),receipt:TronJSON = .object([:])
    var head:TronJSON = .object([:])
    func headResult(_ value:TronJSON){head=value}
    var timestamp=UInt64(Date.now.timeIntervalSince1970*1000)
    init(sender:String,recipient:String){self.sender=sender;self.recipient=recipient}
    func configure(_ values:[String:TronJSON]){options.merge(values){_,new in new}}
    func time(_ value:UInt64){timestamp=value}
    func result(body:TronJSON,receipt:TronJSON){self.body=body;self.receipt=receipt}
    func writes()->[Data]{requests.filter{$0.url!.lastPathComponent=="broadcasthex"}.compactMap(\.httpBody)}
    func contractCalls()->[TronJSON]{requests.filter{$0.url!.lastPathComponent=="triggerconstantcontract"}.compactMap{try? JSONDecoder().decode(TronJSON.self,from:$0.httpBody!)}}
    static func id(_ n:UInt64)->String{String(format:"%016llx",n)+String(repeating:"a",count:48)}
    func block(_ n:UInt64)->TronJSON {
        .object(["blockID":.string(Self.id(n)),"block_header":.object(["raw_data":.object(["number":.number(String(n)),"timestamp":.number(String(timestamp+(n-100)*3000)),"parentHash":.string(Self.id(n-1))])])])
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests.append(request)
        let method=request.url!.lastPathComponent,p=try JSONDecoder().decode(TronJSON.self,from:request.httpBody!)
        if request.url!.host=="rpc.ankr.com",options["fallback"] == .bool(true){return(Data(),503)}
        if options["providerError"] == .bool(true){return(try JSONEncoder().encode(TronJSON.object(["result":.bool(false),"code":.string("SERVER_BUSY"),"message":.string("PRIVATE_RESPONSE_MARKER"),"transaction":p])),200)}
        let result:TronJSON
        switch method {
        case "getblockbynum":result = .object(["blockID":.string(options["wrongNetwork"] == .bool(true) ? String(repeating:"0",count:56)+"cd8690dc":(request.url!.host=="rpc.ankr.com" || options["mainnet"] == .bool(true) ? TronSendNetwork.mainnet.genesisID:TronSendNetwork.nile.genesisID))])
        case "getnowblock":result=block(request.url!.path.contains("solidity") ? 200:100)
        case "getblockbylimitnext":
            var blocks=(p["startNum"].integer!..<p["endNum"].integer!).map{block($0)};if options["missingBlock"] == .bool(true){blocks.removeLast()}
            result = .object(["block":.array(blocks)])
        case "getaccount":
            let address=p["address"].string!
            if address==sender,options["senderInactive"] == .bool(true){result = .object([:])}
            else if address==recipient,options["activation"] == .bool(true){result = .object([:])}
            else {result = .object(["address":.string(address),"balance":options["balance"] ?? .number("1000000000"),"owner_permission":.object(["threshold":.number("1"),"keys":.array([.object(["address":.string(address),"weight":options["weight"] ?? .number("1")])])]),"assetV2":.array([.object(["key":.string("1005416"),"value":.number("10000000")])])])}
        case "getaccountresource":result=options["resources"] ?? .object([:])
        case "getchainparameters":
            var params:[String:TronJSON]=["getTransactionFee":.number("1000"),"getEnergyFee":.number("100"),"getCreateNewAccountFeeInSystemContract":.number("1000000"),"getCreateAccountFee":.number("100000"),"getCreateNewAccountBandwidthRate":.number("1"),"getAllowSameTokenName":.number("1"),"getMaxFeeLimit":.number("15000000000"),"getRemoveThePowerOfTheGr":.number("-1")]
            if let fee=options["energyPrice"]{params["getEnergyFee"]=fee}
            result = .object(["chainParameter":.array(params.map{.object(["key":.string($0.key),"value":$0.value])})])
        case "getassetissuebyid":result = .object(["id":.string("1005416"),"precision":options["decimals"] ?? .number("6")])
        case "triggerconstantcontract":
            let selector=p["function_selector"].string!
            var r:[String:TronJSON]=["result":.object(["result":.bool(true)]),"energy_used":.number("30000")]
            if selector=="transfer(address,uint256)" {
                let parameter=p["parameter"].string!,ref=try TronIdentity.address(p["contract_address"].string!)
                r["constant_result"] = .array([.string(String(repeating:"0",count:63)+(options["zeroReturn"] == .bool(true) ? "0":"1"))])
                r["logs"] = options["missingEvent"] == .bool(true) ? .array([]):.array([try Self.log(sender:sender,recipient:recipient,reference:ref,amount:TronIdentity.uint256(String(parameter.suffix(64))))])
                if options["revert"] == .bool(true){r["transaction"] = .object(["ret":.array([.object(["contractRet":.string("REVERT")])])])}
            } else {let value=selector=="decimals()" ? "6":"10000000";r["constant_result"] = .array([.string(TronSendCrypto.hex(try TronSendCrypto.uint256(value)))])}
            result = .object(r)
        case "gettransactionbyid":result=request.url!.path.contains("solidity") ? body:head
        case "gettransactioninfobyid":result=receipt
        case "broadcasthex":
            if options["timeout"] == .bool(true){throw AnkrError.transport}
            result = options["broadcastResult"] ?? .object(["result":.bool(true)])
        default:throw TronSendError.malformed
        }
        return(try JSONEncoder().encode(result),200)
    }
    static func log(sender:String,recipient:String,reference:String,amount:String) throws -> TronJSON {
        .object(["address":.string(TronSendCrypto.hex(try TronIdentity.bytes(reference).dropFirst())),"topics":.array([.string("ddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"),.string(String(repeating:"0",count:24)+TronSendCrypto.hex(try TronIdentity.bytes(sender).dropFirst())),.string(String(repeating:"0",count:24)+TronSendCrypto.hex(try TronIdentity.bytes(recipient).dropFirst()))]),"data":.string(TronSendCrypto.hex(try TronSendCrypto.uint256(amount)))])
    }
}
@MainActor final class TronSendBoundaryTests:XCTestCase {
    let key=Data(repeating:31,count:32)
    private func fixture(network:TronSendNetwork = .nile) throws ->(TronSendClient,TronSendTransportFixture,String,String){
        let a=try TronSendCrypto.address(privateKey:key),b=try TronSendCrypto.address(privateKey:Data(repeating:32,count:32)),t=TronSendTransportFixture(sender:a,recipient:b)
        return(try TronSendClient(network:network,apiKey:network == .mainnet ? "fixture":nil,transport:t),t,a,b)
    }
    func testActivationAdvicePreservesTRC20ReceivingAndOldPlans() async throws {
        let(c,t,a,b)=try fixture();await t.configure(["activation":.bool(true)])
        for reference in ["native","1005416","TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"] {
            let plan=try await c.quote(sender:a,recipient:b,reference:reference,decimals:6,amount:"1")
            XCTAssertEqual(plan.recipientNeedsActivation,true)
            if !plan.isContract {
                XCTAssertEqual(plan.fee,1_100_000);XCTAssertEqual(plan.accountCost?.atomic,"1100000")
                XCTAssertEqual(plan.feeExcludingAccountCreation+UInt64(plan.accountCost!.atomic)!,plan.fee)
                XCTAssertEqual(plan.accountCost?.inclusion,.networkFee)
            } else { XCTAssertNil(plan.accountCost,"TRC20 must not invent a TRON activation fee") }
            var json=try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(plan)) as? [String:Any])
            json.removeValue(forKey:"recipientNeedsActivation");json.removeValue(forKey:"accountCreationFee")
            let old=try JSONDecoder().decode(TronSendPlan.self,from:JSONSerialization.data(withJSONObject:json))
            XCTAssertNil(old.recipientNeedsActivation);XCTAssertNil(old.accountCost);XCTAssertEqual(old.feeExcludingAccountCreation,old.fee)
            XCTAssertEqual(try TronSendCrypto.raw(old),try TronSendCrypto.raw(plan),"Presentation metadata changed signed bytes")
        }
        await t.configure(["balance":.number("1000000")])
        do { _ = try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1");XCTFail() }
        catch { XCTAssertEqual(error as? TronSendError,.activationFunds(1_100_000)) }
        await t.configure(["senderInactive":.bool(true)])
        do { _ = try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1");XCTFail() }
        catch { XCTAssertEqual(error as? TronSendError,.senderInactive) }
        let writes=await t.writes();XCTAssertTrue(writes.isEmpty)
    }
    func testSignedGovernanceSentinelAndFreshMaximumBalances() async throws {
        let(c,_,a,b)=try fixture()
        let p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"2000000000",maximum:true)
        XCTAssertNil(p.accountCost);XCTAssertEqual(p.feeExcludingAccountCreation,p.fee)
        XCTAssertEqual(UInt64(p.amount)!+p.fee,1_000_000_000);XCTAssertEqual(p.requestedAmount,"1000000000")
        let token=try await c.quote(sender:a,recipient:b,reference:"1005416",decimals:6,amount:"1",maximum:true)
        XCTAssertEqual(token.amount,"10000000")
    }
    func testActivationNeverUsesFreeBandwidthAndIncludesCreationFee() async throws {
        let(c,t,a,b)=try fixture();await t.configure(["activation":.bool(true),"resources":.object(["freeNetLimit":.number("100000")])])
        let p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1")
        XCTAssertEqual(p.estimatedFee,1_100_000);XCTAssertEqual(p.fee,1_100_000)
        await t.configure(["resources":.object(["NetLimit":.number("100000")])])
        let staked=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1")
        XCTAssertEqual(staked.estimatedFee,1_000_000);XCTAssertEqual(staked.accountCost?.atomic,"1000000");XCTAssertEqual(staked.feeExcludingAccountCreation,0)
    }
    func testResourceCoverageAndEnergyHeadroom() async throws {
        let(c,t,a,b)=try fixture();await t.configure(["resources":.object(["NetLimit":.number("1"),"freeNetLimit":.number("10000"),"EnergyLimit":.number("10000")])])
        let p=try await c.quote(sender:a,recipient:b,reference:"TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",decimals:6,amount:"1")
        XCTAssertEqual(p.estimatedFee,2_000_000);XCTAssertEqual(p.feeLimit,4_000_000)
        XCTAssertGreaterThanOrEqual(p.fee,p.estimatedFee)
        let calls=await t.contractCalls();XCTAssertEqual(calls.count,3)
        for call in calls {XCTAssertEqual(call["visible"],.bool(false));XCTAssertEqual(call["owner_address"].string,TronSendCrypto.hex(try TronIdentity.bytes(a)))}
    }
    func testStakedResourcesAllowTokenTransferWithoutLiquidTRX() async throws {
        let(c,t,a,b)=try fixture();await t.configure(["balance":.number("0"),"resources":.object(["NetLimit":.number("10000"),"EnergyLimit":.number("100000")])])
        let p=try await c.quote(sender:a,recipient:b,reference:"TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",decimals:6,amount:"1")
        XCTAssertEqual(p.fee,0);XCTAssertEqual(p.estimatedFee,0);XCTAssertGreaterThan(p.feeLimit,0)
        _=try TronSendCrypto.sign(p,privateKey:key)
    }
    func testBadNetworkPermissionsMetadataAndFeeBoundsStopBeforeSigning() async throws {
        for options:[String:TronJSON] in [["wrongNetwork":.bool(true)],["weight":.number("0")],["energyPrice":.number("-1")],["energyPrice":.number("100001")],["decimals":.number("18")]] {
            let(c,t,a,b)=try fixture();await t.configure(options)
            do{_=try await c.quote(sender:a,recipient:b,reference:"1005416",decimals:6,amount:"1");XCTFail("Unsafe quote accepted")}catch{}
            let writes=await t.writes();XCTAssertTrue(writes.isEmpty)
        }
    }
    func testSimulationRequiresMatchingTransferAndHandlesOnlyPinnedLegacyZeroReturn() async throws {
        let(c,t,a,b)=try fixture();await t.configure(["zeroReturn":.bool(true)])
        _=try await c.quote(sender:a,recipient:b,reference:"TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",decimals:6,amount:"1")
        for options:[String:TronJSON] in [["missingEvent":.bool(true)],["missingEvent":.bool(false),"revert":.bool(true)]] {
            await t.configure(options)
            do{_=try await c.quote(sender:a,recipient:b,reference:"TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf",decimals:6,amount:"1");XCTFail()}catch{XCTAssertEqual(error as? TronSendError,.simulation)}
        }
        await t.configure(["revert":.bool(false)])
        do{_=try await c.quote(sender:a,recipient:b,reference:TronIdentity.usdt,decimals:6,amount:"1");XCTFail("Mainnet address must not get legacy exception on Nile")}catch{XCTAssertEqual(error as? TronSendError,.simulation)}
    }
    func testFallbackAndProviderPrivacy() async throws {
        let(c,t,a,b)=try fixture(network:.mainnet);await t.configure(["fallback":.bool(true),"mainnet":.bool(true)])
        _=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1")
        await t.configure(["providerError":.bool(true)])
        do{_=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1");XCTFail()}catch{XCTAssertEqual(error as? TronSendError,.rpc("SERVER_BUSY"));XCTAssertFalse(String(describing:error).contains("PRIVATE"))}
    }
    func testFreshSubmitDoesNotWaitForSolidityOrMempoolLookup() async throws {
        let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1"),s=try TronSendCrypto.sign(p,privateKey:key)
        let before=await t.requests.count
        let receipt=try await c.submit(s,plan:p,reconcileFirst:false)
        let requests=await t.requests
        XCTAssertEqual(receipt.outcome,.submitted)
        XCTAssertEqual(requests.dropFirst(before).map{$0.url!.lastPathComponent},["broadcasthex"])
    }
    func testAcknowledgedBroadcastIsSubmittedAndTimeoutRetriesExactBytes() async throws {
        let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1"),s=try TronSendCrypto.sign(p,privateKey:key)
        let accepted=try await c.submit(s,plan:p);XCTAssertEqual(accepted.outcome,.submitted)
        XCTAssertTrue(accepted.accepted);XCTAssertTrue(accepted.requiresConfirmation);XCTAssertNil(accepted.fee);XCTAssertNil(accepted.block)
        await t.configure(["timeout":.bool(true)])
        for _ in 0..<2 {do{_=try await c.submit(s,plan:p);XCTFail()}catch{XCTAssertEqual(error as? AnkrError,.transport)}}
        let writes=await t.writes();XCTAssertEqual(writes.count,3);XCTAssertTrue(writes.allSatisfy{$0==writes[0]})
    }
    func testMempoolPresenceDoesNotConfirmOrRebroadcast() async throws {
        let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1"),signed=try TronSendCrypto.sign(p,privateKey:key)
        await t.headResult(.object(["txID":.string(signed.hash),"raw_data_hex":.string(TronSendCrypto.hex(try TronSendCrypto.raw(p))),"signature":.array([.string(TronSendCrypto.hex(signed.signature))])]))
        let result=try await c.submit(signed,plan:p);XCTAssertEqual(result.outcome,.submitted)
        XCTAssertTrue(result.accepted);XCTAssertTrue(result.requiresConfirmation)
        let writes=await t.writes();XCTAssertTrue(writes.isEmpty)
    }
    func testSubmissionAcknowledgementForTRXTRC10AndTRC20NeedsNoSolidReceipt() async throws {
        for reference in ["native","1005416","TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"] {
            let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:reference,decimals:6,amount:"1"),signed=try TronSendCrypto.sign(p,privateKey:key)
            await t.configure(["broadcastResult":.object(["result":.bool(true),"txid":.string(signed.hash)])])
            let result=try await c.submit(signed,plan:p)
            XCTAssertEqual(result.outcome,.submitted);XCTAssertEqual(result.hash,signed.hash)
            // Returning an accepted result must not depend on a second solidity
            // request after broadcast (which may be slow or unavailable).
            let requests=await t.requests
            XCTAssertEqual(requests.last?.url?.lastPathComponent,"broadcasthex")
            XCTAssertFalse(result.outcome == .confirmed)
        }
    }
    func testDuplicateOrMismatchedBroadcastResponseIsNotAssumedSubmitted() async throws {
        let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1"),signed=try TronSendCrypto.sign(p,privateKey:key)
        await t.configure(["broadcastResult":.object(["result":.bool(false),"code":.string("DUP_TRANSACTION_ERROR")])])
        let unknown=try await c.submit(signed,plan:p)
        XCTAssertEqual(unknown.outcome,.unknown);XCTAssertFalse(unknown.accepted)
        await t.configure(["broadcastResult":.object(["result":.bool(true),"txid":.string(String(repeating:"a",count:64))])])
        do{_=try await c.submit(signed,plan:p);XCTFail("Wrong transaction acknowledged")}catch{XCTAssertEqual(error as? TronSendError,.changed)}
        await t.headResult(.object(["txID":.string(signed.hash),"raw_data_hex":.string("00"),"signature":.array([.string(TronSendCrypto.hex(signed.signature))])]))
        do{_=try await c.submit(signed,plan:p);XCTFail("Changed pending transaction accepted")}catch{XCTAssertEqual(error as? TronSendError,.changed)}
    }
    func testReceiptExecutionAndExactSignedBody() async throws {
        let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1"),s=try TronSendCrypto.sign(p,privateKey:key)
        var body:[String:TronJSON]=["txID":.string(s.hash),"raw_data_hex":.string(TronSendCrypto.hex(try TronSendCrypto.raw(p))),"signature":.array([.string(TronSendCrypto.hex(s.signature))]),"ret":.array([.object(["contractRet":.string("SUCCESS")])]),"raw_data":.object(["contract":.array([.object(["type":.string("TransferContract"),"parameter":.object(["value":.object(["owner_address":.string(a),"to_address":.string(b),"amount":.number("1")])])])])])]
        let info:TronJSON = .object(["id":.string(s.hash),"blockNumber":.number("101"),"blockTimeStamp":.number(String(p.timestamp+3000)),"fee":.number("1000")])
        await t.result(body:.object(body),receipt:info);let success=try await c.status(s,plan:p);XCTAssertEqual(success.outcome,.confirmed);XCTAssertEqual(success.fee,1000)
        body["ret"] = .array([.object(["contractRet":.string("OUT_OF_ENERGY")])]);await t.result(body:.object(body),receipt:info)
        let failed=try await c.status(s,plan:p);XCTAssertEqual(failed.outcome,.failed);XCTAssertEqual(failed.fee,1000)
        body["raw_data_hex"] = .string("00");await t.result(body:.object(body),receipt:info)
        do{_=try await c.status(s,plan:p);XCTFail()}catch{XCTAssertEqual(error as? TronSendError,.changed)}
    }
    func testExpiryNeedsContinuousSolidHistoryAndNeverRebroadcasts() async throws {
        let(c,t,a,b)=try fixture(),p=try await c.quote(sender:a,recipient:b,reference:"native",decimals:6,amount:"1")
        let time=p.timestamp-240000
        let old=TronSendPlan(network:p.network,sender:a,recipient:b,reference:p.reference,amount:p.amount,requestedAmount:p.requestedAmount,assetBalance:p.assetBalance,decimals:p.decimals,nativeBalance:p.nativeBalance,fee:p.fee,estimatedFee:p.estimatedFee,feeLimit:p.feeLimit,energyPrice:p.energyPrice,bandwidthPrice:p.bandwidthPrice,blockID:p.blockID,blockNumber:p.blockNumber,timestamp:time,expiration:time+180000,createdAt:Date(timeIntervalSince1970:Double(time)/1000))
        let s=try TronSendCrypto.sign(old,privateKey:key,now:old.createdAt);await t.time(time);await t.configure(["missingBlock":.bool(true)])
        let unknown=try await c.submit(s,plan:old);XCTAssertEqual(unknown.outcome,.unknown)
        await t.configure(["missingBlock":.bool(false)])
        let expired=try await c.submit(s,plan:old);XCTAssertEqual(expired.outcome,.expired)
        let writes=await t.writes();XCTAssertTrue(writes.isEmpty)
    }
}
