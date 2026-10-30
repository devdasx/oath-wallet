import XCTest
import OathDiagnostics
@testable import OathAnkr

actor EVMSendFixtureTransport:AnkrTransport {
    // A block timestamp is immutable across receipt reads.
    private let blockTimestamp = UInt64(Date.now.timeIntervalSince1970)
    var requests=0,broadcasts=0,methods=[String]()
    var estimates=[SolanaJSON]()
    let network:EVMSendNetwork
    var receiptLogs: [SolanaJSON]?
    func setReceiptLogs(_ logs: [SolanaJSON]) { receiptLogs = logs }
    var nativeBalance:String?
    let gasEstimate:UInt64
    var mode:String
    var nonceOverride:(latest:UInt64,pending:UInt64)?
    var pendingNativeBalance:String?,pendingTokenBalance:String?
    var plan:EVMSendPlan?,signed:EVMSignedSend?
    init(_ mode:String="normal",network:EVMSendNetwork = .arbitrum,nativeBalance:String?=nil,gasEstimate:UInt64?=nil) { self.mode=mode;self.network=network;self.nativeBalance=nativeBalance;self.gasEstimate=gasEstimate ?? network.minimumGas }
    func configure(_ p:EVMSendPlan,_ s:EVMSignedSend) { plan=p;signed=s }
    func fund(_ amount: String) { nativeBalance = amount }
    func pending(latest:UInt64=7,nonce:UInt64=8,native:String?=nil,token:String?=nil) {
        nonceOverride=(latest,nonce);pendingNativeBalance=native;pendingTokenBalance=token
    }
    func counts()->(Int,Int) { (requests,broadcasts) }
    private func hex(_ n:UInt64)->SolanaJSON { .string("0x"+String(n,radix:16)) }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        requests+=1
        if mode=="fallback",request.url?.host?.contains("blockdaemon")==true { return (Data(),503) }
        let payload=try JSONDecoder().decode(SolanaJSON.self,from:request.httpBody!)
        let calls=payload.array ?? [payload]
        let rows=try calls.map { call -> SolanaJSON in
            let method=call["method"].string!,params=call["params"].array ?? []
            methods.append(method)
            var result:SolanaJSON = .null
            switch method {
            case "Filecoin.ChainGetTipSetByHeight":
                result = .object(["Height":params[0],"Cids":.array([.object(["/":.string("fixture")])])])
            case "eth_chainId":result=hex(mode=="wrongChain" ? 5042:network.chainID)
            case "eth_getBlockByNumber":
                let height:UInt64 = params[0].string=="0x64" || (mode.hasPrefix("unfinalized") && params[0].string=="finalized") || (mode=="unsealed" && params[0].string=="latest") ? 100:101
                var b:[String:SolanaJSON] = ["number":hex(height),"hash":.string("0x"+String(repeating:"a",count:64)),"baseFeePerGas":hex(20_000_000_000),"timestamp":hex(blockTimestamp)]
                if params.last == .bool(true),let p=plan {
                    b["transactions"] = .array([.object(["from":.string(p.sender),"to":.string(mode=="cancelled" ? p.sender:p.recipient),"nonce":hex(p.nonce),"hash":.string("0x"+String(repeating:"b",count:64)),"value":.string(mode=="cancelled" ? "0x0":"0x1"),"input":.string("0x")])])
                };if mode=="legacy" { b.removeValue(forKey:"baseFeePerGas") }
                if mode=="reorged" { b["hash"] = .string("0x"+String(repeating:"b",count:64)) }
                result = .object(b)
            case "eth_getBalance":result = .string(try (params.last?.string=="pending" ? pendingNativeBalance ?? nativeBalance:nativeBalance).map(EVMSendAmount.hex) ?? (mode=="empty" ? "0x0":"0x3635c9adc5dea00000")) // 1000 native units
            case "eth_getTransactionCount":
                if let n=nonceOverride { result=hex(params.last?.string=="pending" ? n.pending:n.latest) }
                else { result=hex(mode=="pending" && params.last?.string=="pending" ? 8 : ["replaced","cancelled"].contains(mode) ? 8:7) }
            case "linea_estimateGas":
                guard params[0]["maxFeePerGas"].isNull,params[0]["maxPriorityFeePerGas"].isNull else { throw EVMSendError.changed };result = .object(["gasLimit":hex(21000),"baseFeePerGas":hex(20_000_000_000),"priorityFeePerGas":hex(2_000_000_000)])
            case "eth_gasPrice":result=hex(mode=="expensive" ? 100_000_000_000_001:21_000_000_000)
            case "eth_maxPriorityFeePerGas":result=hex(1_000_000_000)
            case "eth_estimateGas":
                estimates.append(params[0])
                if ["celoAffordability","celoTokenAffordability"].contains(mode) {
                    let value=try IndexedEVMIdentity.amount(params[0]["value"])
                    guard value != "0" || mode=="celoTokenAffordability" else { throw EVMSendError.simulationFailed }
                    let cap=UInt64((params[0]["maxFeePerGas"].string ?? "0x0").dropFirst(2),radix:16) ?? 0
                    if let nativeBalance,EVMSendAmount.less(nativeBalance,try EVMSendAmount.add(value,String(cap*gasEstimate))) { if mode=="celoTokenAffordability" { throw EVMSendError.rpc(-32000) };throw SendFeeFundingError.insufficientNativeBalance }
                }
                result=hex(mode=="gasOverflow" ? UInt64.max:gasEstimate)
            case "eth_call":
                let data=params[0]["data"].string ?? ""
                if params[0]["to"].string==network.oracle { result=hex(1000) }
                else if data=="0x313ce567" { result=hex(mode=="decimals" ? 18:6) }
                else if data.hasPrefix("0x70a08231") { result = .string(try (params.last?.string=="pending" ? pendingTokenBalance:nil).map(EVMSendAmount.hex) ?? "0x0f4240") }
                else { result = .string(data=="0x" ? "0x":"0x"+String(repeating:"0",count:63)+(mode=="falseToken" ? "0":"1")) }
            case "eth_getTransactionByHash":
                if ["confirmed","failed","tampered","partialToken","missingToken","unfinalized","unfinalizedFailed","unfinalizedMalformed","unsealed","unfinalizedUnavailable","reorged"].contains(mode),let p=plan,let s=signed {
                    result = .object(["hash":.string(s.hash),"from":.string(p.sender),"to":.string(mode=="tampered" ? p.sender:p.receiver),
                        "chainId":hex(p.network.chainID),"type":hex(p.legacy ? 0:2),"gasPrice":hex(p.maxFeePerGas),"nonce":hex(p.nonce),"gas":hex(p.gasLimit),"maxFeePerGas":hex(p.maxFeePerGas),"maxPriorityFeePerGas":hex(p.maxPriorityFeePerGas),
                        "value":.string(try EVMSendAmount.hex(p.value)),"input":.string("0x"+TronSendCrypto.hex(try EVMSendCrypto.data(p))),"blockNumber":hex(101),"blockHash":.string("0x"+String(repeating:"a",count:64))])
                }
            case "eth_getTransactionReceipt":
                if ["confirmed","failed","tampered","partialToken","missingToken","unfinalized","unfinalizedFailed","unfinalizedMalformed","unsealed","unfinalizedUnavailable","reorged"].contains(mode),let p=plan,let s=signed {
                    result = .object(["transactionHash":.string(s.hash),"from":.string(p.sender),"to":.string(p.receiver),"blockNumber":hex(101),"blockHash":.string("0x"+String(repeating:"a",count:64)),"status":hex(mode=="unfinalizedMalformed" ? 2 : ["failed","unfinalizedFailed"].contains(mode) ? 0:1),"gasUsed":hex(network.minimumGas),"effectiveGasPrice":hex(network.isFilecoin ? try FilecoinSendFee.actual(gasUsed:21000,gasLimit:p.gasLimit,baseFee:20_000_000_000,feeCap:p.maxFeePerGas,premium:p.maxPriorityFeePerGas)/21000 : 20_000_000_000),"l1Fee":hex(1000),"logs":.array(try receiptLogs ?? (p.reference == "native" || mode == "missingToken" ? []:[.object(["address":.string(p.reference),"topics":.array([.string(EVMSendIdentity.transferTopic),.string("0x"+String(repeating:"0",count:24)+p.sender.dropFirst(2)),.string("0x"+String(repeating:"0",count:24)+p.recipient.dropFirst(2))]),"data":.string(try EVMSendAmount.hex(mode == "partialToken" ? EVMSendAmount.subtract(p.amount,"1"):p.amount))])]))])
                }
            case "eth_sendRawTransaction":broadcasts+=1;result = .string(signed?.hash ?? "")
            default:throw EVMSendError.malformed
            }
            if (mode=="unfinalizedUnavailable" && method=="eth_getBlockByNumber" && params[0].string=="finalized") || (mode=="rpcError" && method != "eth_chainId") || (mode=="missingMethod" && method=="linea_estimateGas" && request.url?.host=="blockdaemon.example") {
                return .object(["jsonrpc":.string("2.0"),"id":call["id"],"error":.object(["code":.number(mode=="missingMethod" ? "-32601":"-32000"),"message":.string("execution reverted")])])
            }
            return .object(["jsonrpc":.string("2.0"),"id":mode=="duplicateID" ? .number("0"):call["id"],"result":result])
        }
        return (try JSONEncoder().encode((payload.array == nil ? rows[0] : SolanaJSON.array(rows.reversed()))),200)
    }
}

@MainActor final class EVMSendRPCRegressionTests:XCTestCase {
    let key=Data(repeating:1,count:32)
    func quote(_ transport:EVMSendFixtureTransport,token:Bool=false,max:Bool=false,reservations:[EVMSendReservation]=[]) async throws -> (EVMSendClient,EVMSendPlan) {
        let client=try EVMSendClient(network:transport.network,endpoints:[URL(string:"https://blockdaemon.example")!,URL(string:"https://fallback.example")!],transport:transport)
        let p=try await client.quote(sender:EVMSendCrypto.address(privateKey:key),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:token ? "0x"+String(repeating:"3",count:40):"native",decimals:token ? 6:18,amount:token ? "123":"1000000000000000000",maximum:max,reservations:reservations)
        return (client,p)
    }
    func testEveryNetworkFreshNativeAndTokenSubmitSkipsRecovery() async throws {
        for network in EVMSendNetwork.allCases {
            for token in [false,true] {
                let t=EVMSendFixtureTransport(network:network), (c,p)=try await quote(t,token:token),s=try EVMSendCrypto.sign(p,privateKey:key)
                await t.configure(p,s);let before=await t.methods.count
                let receipt=try await c.submit(s,plan:p,reconcileFirst:false)
                XCTAssertEqual(receipt.outcome,.accepted)
                let calls=await t.methods;XCTAssertEqual(Array(calls.dropFirst(before)),["eth_chainId","eth_sendRawTransaction"],network.rawValue)
            }
        }
    }
    func testEverySupportedNetworkNativeTokenAndMax() async throws {
        for network in EVMSendNetwork.allCases {
            for token in [false,true] {
                let (_,p)=try await quote(EVMSendFixtureTransport(network:network),token:token,max:true)
                XCTAssertEqual(p.network,network)
                XCTAssertEqual(p.remaining,"0")
                let signed=try EVMSendCrypto.sign(p,privateKey:key)
                try EVMSendCrypto.verify(signed,plan:p)
                XCTAssertEqual(p.extraFee>0,network.oracle != nil)
            }
        }
    }
    func testLegacyAndL2FeeReceipts() async throws {
        for (network,mode) in [(EVMSendNetwork.telos,"legacy"),(.optimism,"normal"),(.base,"normal"),(.scroll,"normal"),(.linea,"normal")] {
            let (_,p)=try await quote(EVMSendFixtureTransport(mode,network:network),max:true)
            XCTAssertEqual(p.legacy,mode=="legacy")
            let signed=try EVMSendCrypto.sign(p,privateKey:key),transport=EVMSendFixtureTransport("confirmed",network:network)
            await transport.configure(p,signed)
            let receipt=try await EVMSendClient(network:network,endpoints:[URL(string:"https://test.example")!],transport:transport).status(signed,plan:p)
            XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertEqual(receipt.fee,420_000_000_000_000+(network.opStack ? 2000:network.oracle == nil ? 0:1000))
            if network == .linea { XCTAssertEqual(p.maxPriorityFeePerGas,2_000_000_000) }
        }
    }
    func testQuoteMaxAndPreflightUseNativeGasReserve() async throws {
        let (client,p)=try await quote(EVMSendFixtureTransport(),max:true)
        XCTAssertEqual(try EVMSendAmount.add(p.amount,String(p.fee)),p.nativeBalance)
        XCTAssertEqual(p.decimals,18);XCTAssertEqual(p.maxFeePerGas,41000000000)
        try await client.preflight(p)
        let (_,t)=try await quote(EVMSendFixtureTransport(),token:true,max:true)
        XCTAssertEqual(t.amount,"1000000");XCTAssertEqual(t.remaining,"0");XCTAssertGreaterThan(t.fee,0)
    }
    func testWrongChainMismatchedIDsPendingNonceAndFeeFailuresReject() async throws {
        for mode in ["wrongChain","duplicateID","empty","expensive","gasOverflow","rpcError"] {
            do { _ = try await quote(EVMSendFixtureTransport(mode));XCTFail(mode) } catch {}
        }
        for mode in ["decimals","falseToken"] {
            do { _ = try await quote(EVMSendFixtureTransport(mode),token:true);XCTFail(mode) } catch {}
        }
    }
    func testIndependentFallbackIsChainChecked() async throws {
        let transport=EVMSendFixtureTransport("fallback")
        _ = try await quote(transport)
        let counts=await transport.counts();XCTAssertGreaterThan(counts.0,10)
    }
    func testUnsupportedLineaMethodUsesChainVerifiedProviderFallback() async throws {
        let (client,plan)=try await quote(EVMSendFixtureTransport("missingMethod",network:.linea))
        XCTAssertEqual(plan.maxPriorityFeePerGas,2_000_000_000)
        try await client.preflight(plan)
    }
    func testNegativeRPCRejectionIsPreservedWithoutProviderRetry() async throws {
        let transport=EVMSendFixtureTransport("rpcError")
        do { _ = try await quote(transport);XCTFail("Expected execution rejection") }
        catch { XCTAssertEqual(error as? EVMSendError,.rpc(-32000)) }
        let counts=await transport.counts();XCTAssertEqual(counts.0,1)
    }
    func testPendingPredecessorAllowsAnotherNativeAndTokenSend() async throws {
        for network in EVMSendNetwork.allCases where network != .hyperevm {
            for token in [false,true] {
                let (client,next)=try await quote(EVMSendFixtureTransport("pending",network:network),token:token)
                XCTAssertEqual(next.nonce,8,network.rawValue)
                try await client.preflight(next)
            }
        }
    }

    func testLocalCommitmentsReserveNextNonceTokenAmountAndMaximumGasAcrossNetworks() async throws {
        for network in EVMSendNetwork.allCases {
            for token in [false,true] {
                let (_,first)=try await quote(EVMSendFixtureTransport(network:network),token:token)
                let reservation=try EVMSendReservation(plan:first,hash:EVMSendCrypto.sign(first,privateKey:key).hash)
                // Provider has not seen our first broadcast yet. The durable
                // journal must still prevent reusing its nonce or its funds.
                let (client,next)=try await quote(EVMSendFixtureTransport(network:network),token:token,max:true,reservations:[reservation])
                XCTAssertEqual(next.nonce,8,network.rawValue)
                XCTAssertEqual(next.nativeBalance,try EVMSendAmount.subtract(first.nativeBalance,reservation.nativeCost))
                XCTAssertEqual(next.assetBalance,try EVMSendAmount.subtract(first.assetBalance,token ? first.amount:reservation.nativeCost))
                XCTAssertEqual(next.remaining,"0")
                try await client.preflight(next)
            }
        }
    }

    func testObservedPendingBalanceIsNotDoubleSubtractedAndIncomingFundsAreNotAdvanced() async throws {
        let (_,first)=try await quote(EVMSendFixtureTransport(network:.ethereum),token:true)
        let row=try EVMSendReservation(plan:first,hash:EVMSendCrypto.sign(first,privateKey:key).hash)
        let native=try EVMSendAmount.subtract(first.nativeBalance,row.nativeCost)
        let asset=try EVMSendAmount.subtract(first.assetBalance,row.amount)
        let t=EVMSendFixtureTransport(network:.ethereum)
        await t.pending(native:native,token:asset)
        let (client,next)=try await quote(t,token:true,max:true,reservations:[row])
        XCTAssertEqual(next.assetBalance,asset);XCTAssertEqual(next.nativeBalance,native)
        try await client.preflight(next)
        await t.pending(native:first.nativeBalance,token:"2000000")
        let (_,incoming)=try await quote(t,token:true,max:true,reservations:[row])
        XCTAssertEqual(incoming.amount,asset,"Unconfirmed incoming value must not finance another send")
    }

    func testPreflightRechecksReservationsAndRejectsStaleNonceOrNewlySpentFunds() async throws {
        let t=EVMSendFixtureTransport(network:.ethereum)
        let (_,first)=try await quote(t,token:true)
        let row=try EVMSendReservation(plan:first,hash:EVMSendCrypto.sign(first,privateKey:key).hash)
        let (client,next)=try await quote(t,token:true,reservations:[row])
        await t.pending(nonce:9)
        do { try await client.preflight(next);XCTFail("Another transaction already occupies reviewed nonce") }
        catch { XCTAssertEqual(error as? EVMSendError,.changed) }
        await t.pending(nonce:8,token:"100")
        do { try await client.preflight(next);XCTFail("Token funds spent since review") }
        catch { XCTAssertEqual(error as? EVMSendError,.insufficientFunds) }
        await t.pending(latest:6,nonce:8)
        do { try await client.preflight(next);XCTFail("Reorg requires a new quote") }
        catch { XCTAssertEqual(error as? EVMSendError,.changed) }
        await t.pending(latest:8,nonce:8)
        try await client.preflight(next) // Predecessor mined while approval was open.
        let (_,mined)=try await quote(t,token:true,reservations:[row])
        XCTAssertEqual(mined.assetBalance,first.assetBalance,"Mined amounts are already reflected by RPC")
        XCTAssertEqual(mined.pendingState?.reservations.count,0)
    }

    func testReservationIdentityDuplicatesAndNonceGapsAreRejected() async throws {
        let (_,p)=try await quote(EVMSendFixtureTransport(network:.ethereum))
        let row=try EVMSendReservation(plan:p,hash:EVMSendCrypto.sign(p,privateKey:key).hash)
        for (network,rows,latest,pending) in [(EVMSendNetwork.base,[row],7,7),(.ethereum,[row,row],7,7),(.ethereum,[row],6,6)] {
            let t=EVMSendFixtureTransport(network:network);await t.pending(latest:UInt64(latest),nonce:UInt64(pending))
            do { _ = try await quote(t,reservations:rows);XCTFail("Invalid pending commitment") }
            catch { XCTAssertEqual(error as? EVMSendError,.changed) }
        }
    }

    func testContractEffectsRequirePendingVisibilityAndDelegationReservesTwoNonces() async throws {
        let (_,p)=try await quote(EVMSendFixtureTransport(network:.ethereum))
        let hash="0x"+String(repeating:"a",count:64)
        let contract=EVMSendPlan(network:p.network,sender:p.sender,recipient:p.recipient,reference:"native",decimals:18,
            requestedAmount:"0",amount:"0",assetBalance:p.nativeBalance,nativeBalance:p.nativeBalance,nonce:p.nonce,
            gasLimit:50000,maxFeePerGas:p.maxFeePerGas,maxPriorityFeePerGas:p.maxPriorityFeePerGas,blockHeight:p.blockHeight,call:try EVMContractCall(hex:"0x12345678"))
        let row=try EVMSendReservation(plan:contract,hash:hash)
        let t=EVMSendFixtureTransport(network:.ethereum)
        do { _ = try await quote(t,token:true,reservations:[row]);XCTFail("Opaque unobserved effects cannot be skipped") }
        catch { XCTAssertEqual(error as? EVMSendError,.busy) }
        await t.pending()
        let (client,visible)=try await quote(t,token:true,reservations:[row])
        XCTAssertEqual(visible.nonce,8);try await client.preflight(visible)

        let removal=EVMPermissionRemoval(kind:.delegation,contract:p.sender,spender:p.recipient,expected:p.recipient)
        let delegation=EVMSendPlan(network:p.network,sender:p.sender,recipient:p.sender,reference:"native",decimals:18,
            requestedAmount:"0",amount:"0",assetBalance:p.nativeBalance,nativeBalance:p.nativeBalance,nonce:7,
            gasLimit:50000,maxFeePerGas:p.maxFeePerGas,maxPriorityFeePerGas:p.maxPriorityFeePerGas,blockHeight:p.blockHeight,removal:removal)
        let clear=try EVMSendReservation(plan:delegation,hash:hash)
        XCTAssertEqual(clear.lastNonce,8)
        let (nextClient,next)=try await quote(EVMSendFixtureTransport(network:.ethereum),reservations:[clear])
        XCTAssertEqual(next.nonce,9);try await nextClient.preflight(next)
    }

    func testReceiptConfirmationFailureAndTampering() async throws {
        for mode in ["confirmed","failed","tampered","replaced","cancelled"] {
            let (_,p)=try await quote(EVMSendFixtureTransport())
            let signed=try EVMSendCrypto.sign(p,privateKey:key),transport=EVMSendFixtureTransport(mode)
            await transport.configure(p,signed)
            let client=try EVMSendClient(network:transport.network,endpoints:[URL(string:"https://blockdaemon.example")!,URL(string:"https://fallback.example")!],transport:transport)
            if mode=="tampered" { do { _ = try await client.status(signed,plan:p);XCTFail() } catch {};continue }
            let result=try await client.status(signed,plan:p)
            XCTAssertEqual(result.outcome.rawValue,mode)
            let replay=try await client.submit(signed,plan:p);XCTAssertEqual(replay.outcome,result.outcome)
            let counts=await transport.counts();XCTAssertEqual(counts.1,0)
        }
    }
    func testTokenExecutionAndDeliveredAmountAreIndependent() async throws {
        for mode in ["confirmed","partialToken","missingToken","failed"] {
            let (_,p)=try await quote(EVMSendFixtureTransport(),token:true)
            let signed=try EVMSendCrypto.sign(p,privateKey:key),transport=EVMSendFixtureTransport(mode)
            await transport.configure(p,signed)
            let receipt=try await EVMSendClient(network:.arbitrum,endpoints:[URL(string:"https://test.example")!],transport:transport).status(signed,plan:p)
            XCTAssertEqual(receipt.outcome,mode == "failed" ? .failed:.confirmed)
            let expected:String? = switch mode { case "failed":nil;case "partialToken":"122";case "missingToken":"0";default:p.amount }
            XCTAssertEqual(receipt.deliveredAmount,expected)
        }
    }
    func testEveryEVMNetworkExposesVerifiedInclusionBeforeFinality() async throws {
        for network in EVMSendNetwork.allCases where network.finalityTag != "latest" {
            for token in [false, true] {
                let (_,p)=try await quote(EVMSendFixtureTransport(network:network),token:token)
                let signed=try EVMSendCrypto.sign(p,privateKey:key)
                for mode in ["unfinalized", "unfinalizedFailed", "unfinalizedUnavailable"] {
                    let transport=EVMSendFixtureTransport(mode,network:network)
                    await transport.configure(p,signed)
                    let client=try EVMSendClient(network:network,endpoints:[URL(string:"https://test.example")!],transport:transport)
                    let receipt=try await client.status(signed,plan:p)
                    XCTAssertEqual(receipt.outcome,.accepted,network.rawValue)
                    XCTAssertNil(receipt.fee,"The durable journal must still wait for finality")
                    let inclusion=try XCTUnwrap(receipt.inclusion,network.rawValue)
                    XCTAssertEqual(inclusion.succeeded,mode != "unfinalizedFailed")
                    XCTAssertEqual(inclusion.height,101)
                    XCTAssertEqual(inclusion.deliveredAmount,mode != "unfinalizedFailed" && token ? p.amount:nil)
                }
            }
        }
    }
    func testPreconfirmationAndMalformedReceiptCannotDisplayConfirmation() async throws {
        let (_,p)=try await quote(EVMSendFixtureTransport(network:.base),token:true)
        let signed=try EVMSendCrypto.sign(p,privateKey:key)
        for mode in ["unsealed", "reorged", "unfinalizedMalformed", "tampered"] {
            let transport=EVMSendFixtureTransport(mode,network:.base);await transport.configure(p,signed)
            let client=try EVMSendClient(network:.base,endpoints:[URL(string:"https://test.example")!],transport:transport)
            do {
                let receipt=try await client.status(signed,plan:p)
                XCTAssertTrue(["unsealed", "reorged"].contains(mode))
                XCTAssertEqual(receipt.outcome,.accepted);XCTAssertNil(receipt.inclusion)
            } catch { XCTAssertFalse(["unsealed", "reorged"].contains(mode)) }
        }
    }
    func testProviderMessagesUseSharedPrivacyFilter() throws {
        let account="0x"+String(repeating:"d",count:40),credential=String(repeating:"abcdef",count:12)
        let event=DiagnosticEvent(error:DiagnosticFailure("execution reverted for \(account) at https://rpc.ankr.com/arbitrum/\(credential)"),
            component:"evm_send",operation:"rpc_response",context:["chain":"arbitrum","rpc_code":"-32000"],sessionID:UUID())
        let encoded=String(decoding:try JSONEncoder().encode(event),as:UTF8.self)
        XCTAssertFalse(encoded.contains(account));XCTAssertFalse(encoded.contains(credential))
        XCTAssertEqual(event.context["chain"],"arbitrum");XCTAssertEqual(event.context["rpc_code"],"-32000")
        XCTAssertTrue(event.error.message.contains("execution reverted"))
    }
    func testUnknownAndBroadcastAcceptanceRemainNonterminal() async throws {
        let transport=EVMSendFixtureTransport(),(client,p)=try await quote(transport)
        let signed=try EVMSendCrypto.sign(p,privateKey:key);await transport.configure(p,signed)
        let unknown=try await client.status(signed,plan:p);XCTAssertEqual(unknown.outcome,.unknown)
        let accepted=try await client.submit(signed,plan:p);XCTAssertEqual(accepted.outcome,.accepted)
        XCTAssertNil(accepted.fee);XCTAssertNil(accepted.height);XCTAssertNil(accepted.inclusion)
    }
}
