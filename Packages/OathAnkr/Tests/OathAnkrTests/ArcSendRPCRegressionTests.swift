import XCTest
@testable import OathAnkr

actor ArcSendFixtureTransport:AnkrTransport {
    var requests=0,broadcasts=0
    var mode:String
    var plan:ArcSendPlan?,signed:ArcSignedSend?
    init(_ mode:String="normal") { self.mode=mode }
    func configure(_ p:ArcSendPlan,_ s:ArcSignedSend) { plan=p;signed=s }
    func counts()->(Int,Int) { (requests,broadcasts) }
    private func hex(_ n:UInt64)->SolanaJSON { .string("0x"+String(n,radix:16)) }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests+=1
        if mode=="fallback",request.url?.host?.contains("blockdaemon")==true { return (Data(),503) }
        let calls=try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!).array!
        let rows=try calls.map { call -> SolanaJSON in
            let method=call["method"].string!,params=call["params"].array ?? []
            var result:SolanaJSON = .null
            switch method {
            case "eth_chainId":result=hex(mode=="wrongChain" ? 1:5042)
            case "eth_getBlockByNumber":
                let height:UInt64 = params[0].string=="0x64" ? 100:101
                var b:[String:SolanaJSON] = ["number":hex(height),"hash":.string("0x"+String(repeating:"a",count:64)),"baseFeePerGas":hex(20_000_000_000),"timestamp":hex(UInt64(Date.now.timeIntervalSince1970))]
                if params.last == .bool(true),let p=plan {
                    b["transactions"] = .array([.object(["from":.string(p.sender),"to":.string(mode=="cancelled" ? p.sender:p.recipient),"nonce":hex(p.nonce),"hash":.string("0x"+String(repeating:"b",count:64)),"value":.string(mode=="cancelled" ? "0x0":"0x1"),"input":.string("0x")])])
                };result = .object(b)
            case "eth_getBalance":result = .string(mode=="empty" ? "0x0":"0x3635c9adc5dea00000") // 1000 USDC
            case "eth_getTransactionCount":result=hex(mode=="pending" && params.last?.string=="pending" ? 8 : ["replaced","cancelled"].contains(mode) ? 8:7)
            case "eth_gasPrice":result=hex(mode=="expensive" ? 100_000_000_000_001:21_000_000_000)
            case "eth_estimateGas":result=hex(mode=="gasOverflow" ? UInt64.max:21_000)
            case "eth_call":
                let data=params[0]["data"].string ?? ""
                if data=="0x313ce567" { result=hex(mode=="decimals" ? 18:6) }
                else if data.hasPrefix("0x70a08231") { result = .string("0x0f4240") }
                else { result = .string(data=="0x" ? "0x":"0x"+String(repeating:"0",count:63)+(mode=="falseToken" ? "0":"1")) }
            case "eth_getTransactionByHash":
                if ["confirmed","failed","tampered","partialToken","missingToken"].contains(mode),let p=plan,let s=signed {
                    result = .object(["hash":.string(s.hash),"from":.string(p.sender),"to":.string(mode=="tampered" ? p.sender:p.receiver),
                        "chainId":hex(p.network.chainID),"type":hex(2),"nonce":hex(p.nonce),"gas":hex(p.gasLimit),"maxFeePerGas":hex(p.maxFeePerGas),"maxPriorityFeePerGas":hex(p.maxPriorityFeePerGas),
                        "value":.string(try ArcSendAmount.hex(p.value)),"input":.string("0x"+TronSendCrypto.hex(try ArcSendCrypto.data(p))),"blockNumber":hex(101),"blockHash":.string("0x"+String(repeating:"a",count:64))])
                }
            case "eth_getTransactionReceipt":
                if ["confirmed","failed","tampered","partialToken","missingToken"].contains(mode),let p=plan,let s=signed {
                    result = .object(["transactionHash":.string(s.hash),"from":.string(p.sender),"to":.string(p.receiver),"blockNumber":hex(101),"blockHash":.string("0x"+String(repeating:"a",count:64)),"status":hex(mode=="failed" ? 0:1),"gasUsed":hex(21000),"effectiveGasPrice":hex(20_000_000_000),"logs":.array(p.reference == "native" || mode == "missingToken" ? []:[.object(["address":.string(p.reference),"topics":.array([.string(ArcIdentity.transferTopic),.string("0x"+String(repeating:"0",count:24)+p.sender.dropFirst(2)),.string("0x"+String(repeating:"0",count:24)+p.recipient.dropFirst(2))]),"data":.string(try ArcSendAmount.hex(mode == "partialToken" ? ArcSendAmount.subtract(p.amount,"1"):p.amount))])])])
                }
            case "eth_sendRawTransaction":broadcasts+=1;result = .string(signed?.hash ?? "")
            default:throw ArcSendError.malformed
            }
            if mode=="rpcError",method != "eth_chainId" {
                return .object(["jsonrpc":.string("2.0"),"id":call["id"],"error":.object(["code":.number("-32000"),"message":.string("execution reverted")])])
            }
            return .object(["jsonrpc":.string("2.0"),"id":mode=="duplicateID" ? .number("0"):call["id"],"result":result])
        }
        return (try JSONEncoder().encode(SolanaJSON.array(rows.reversed())),200)
    }
}

@MainActor final class ArcSendRPCRegressionTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func quote(_ transport:ArcSendFixtureTransport,token:Bool=false,max:Bool=false) async throws -> (ArcSendClient,ArcSendPlan) {
        let client=ArcSendClient(transport:transport)
        let p=try await client.quote(sender:ArcSendCrypto.address(privateKey:key),recipient:ArcSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:token ? "0x"+String(repeating:"3",count:40):"native",decimals:token ? 6:18,amount:token ? "123":"1000000000000000000",maximum:max)
        return (client,p)
    }
    func testFreshNativeAndTokenSubmitSkipsRecovery() async throws {
        for token in [false,true] {
            let t=ArcSendFixtureTransport(),(c,p)=try await quote(t,token:token),s=try ArcSendCrypto.sign(p,privateKey:key)
            await t.configure(p,s);let before=await t.counts()
            let result=try await c.submit(s,plan:p,reconcileFirst:false)
            let after=await t.counts();XCTAssertEqual(result.outcome,.accepted);XCTAssertEqual(after.0-before.0,1);XCTAssertEqual(after.1-before.1,1)
        }
    }
    func testQuoteMaxAndPreflightUseNativeUSDCGasReserve() async throws {
        let (client,p)=try await quote(ArcSendFixtureTransport(),max:true)
        XCTAssertEqual(try ArcSendAmount.add(p.amount,String(p.fee)),p.nativeBalance)
        XCTAssertEqual(p.decimals,18);XCTAssertEqual(p.maxFeePerGas,41000000000)
        try await client.preflight(p)
        let (_,t)=try await quote(ArcSendFixtureTransport(),token:true,max:true)
        XCTAssertEqual(t.amount,"1000000");XCTAssertEqual(t.remaining,"0");XCTAssertGreaterThan(t.fee,0)
    }
    func testWrongChainMismatchedIDsPendingNonceAndFeeFailuresReject() async throws {
        for mode in ["wrongChain","duplicateID","pending","empty","expensive","gasOverflow","rpcError"] {
            do { _ = try await quote(ArcSendFixtureTransport(mode));XCTFail(mode) } catch {}
        }
        for mode in ["decimals","falseToken"] {
            do { _ = try await quote(ArcSendFixtureTransport(mode),token:true);XCTFail(mode) } catch {}
        }
    }
    func testIndependentFallbackIsChainChecked() async throws {
        let transport=ArcSendFixtureTransport("fallback")
        _ = try await quote(transport)
        let counts=await transport.counts();XCTAssertGreaterThan(counts.0,10)
    }
    func testNegativeRPCRejectionIsPreservedWithoutProviderRetry() async throws {
        let transport=ArcSendFixtureTransport("rpcError")
        do { _ = try await quote(transport);XCTFail("Expected execution rejection") }
        catch { XCTAssertEqual(error as? ArcSendError,.rpc(-32000)) }
        let counts=await transport.counts();XCTAssertEqual(counts.0,1)
    }
    func testReceiptConfirmationFailureAndTampering() async throws {
        for mode in ["confirmed","failed","tampered","replaced","cancelled"] {
            let (_,p)=try await quote(ArcSendFixtureTransport())
            let signed=try ArcSendCrypto.sign(p,privateKey:key),transport=ArcSendFixtureTransport(mode)
            await transport.configure(p,signed)
            let client=ArcSendClient(transport:transport)
            if mode=="tampered" { do { _ = try await client.status(signed,plan:p);XCTFail() } catch {};continue }
            let result=try await client.status(signed,plan:p)
            XCTAssertEqual(result.outcome.rawValue,mode)
            let replay=try await client.submit(signed,plan:p);XCTAssertEqual(replay.outcome,result.outcome)
            let counts=await transport.counts();XCTAssertEqual(counts.1,0)
        }
    }
    func testTokenExecutionAndDeliveredAmountAreIndependent() async throws {
        for mode in ["confirmed","partialToken","missingToken","failed"] {
            let (_,p)=try await quote(ArcSendFixtureTransport(),token:true)
            let signed=try ArcSendCrypto.sign(p,privateKey:key),transport=ArcSendFixtureTransport(mode)
            await transport.configure(p,signed)
            let receipt=try await ArcSendClient(transport:transport).status(signed,plan:p)
            XCTAssertEqual(receipt.outcome,mode == "failed" ? .failed:.confirmed)
            let expected:String? = switch mode { case "failed":nil;case "partialToken":"122";case "missingToken":"0";default:p.amount }
            XCTAssertEqual(receipt.deliveredAmount,expected)
        }
    }
    func testUnknownAndBroadcastAcceptanceRemainNonterminal() async throws {
        let transport=ArcSendFixtureTransport(),(client,p)=try await quote(transport)
        let signed=try ArcSendCrypto.sign(p,privateKey:key);await transport.configure(p,signed)
        let unknown=try await client.status(signed,plan:p);XCTAssertEqual(unknown.outcome,.unknown)
        let accepted=try await client.submit(signed,plan:p);XCTAssertEqual(accepted.outcome,.accepted)
        XCTAssertNil(accepted.fee);XCTAssertNil(accepted.height)
    }
}
