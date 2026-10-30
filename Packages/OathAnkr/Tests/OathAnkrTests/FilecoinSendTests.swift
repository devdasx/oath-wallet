import XCTest
@testable import OathAnkr

@MainActor final class FilecoinSendTests: XCTestCase {
    func testRemainingBalancePaysFirstAndOnlyShortfallReducesPayment() async throws {
        for network in [EVMSendNetwork.filecoin, .filecoinCalibration] {
            let balance="1000000000000000000",fee:UInt64=861000000000000
            for (amount,max,expected) in [("100000000000000000",false,"100000000000000000"),
                ("999999999999999999",false,try EVMSendAmount.subtract(balance,String(fee))),
                (balance,false,try EVMSendAmount.subtract(balance,String(fee))),
                ("1",true,try EVMSendAmount.subtract(balance,String(fee)))] {
                let transport=EVMSendFixtureTransport("celoAffordability",network:network,nativeBalance:balance)
                let client=try EVMSendClient(network:network,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
                let plan=try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:amount,maximum:max)
                XCTAssertEqual(plan.amount,expected);XCTAssertEqual(plan.fee,fee)
                let estimates=await transport.estimates
                XCTAssertEqual(try IndexedEVMIdentity.amount(estimates[0]["value"]),max ? balance:amount)
                XCTAssertTrue(estimates[0]["maxFeePerGas"].isNull)
                XCTAssertFalse(estimates[1]["maxFeePerGas"].isNull)
                XCTAssertEqual(try IndexedEVMIdentity.amount(estimates[1]["value"]),expected)
                try await client.preflight(plan)
                try EVMSendCrypto.verify(EVMSendCrypto.sign(plan,privateKey:Data(repeating:1,count:32)),plan:plan)
            }
        }
    }
    func testExactFeeBudgetCannotBecomeAZeroValuePayment() async throws {
        let client=try EVMSendClient(network:.filecoin,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.filecoin,nativeBalance:"861000000000000"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
            XCTFail("The gas budget leaves no positive payment")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testTokenFeeShortageIsDetectedBeforeFinalSimulation() async throws {
        let transport=EVMSendFixtureTransport("celoTokenAffordability",network:.filecoin,nativeBalance:"1000000000000000",gasEstimate:60_000)
        let client=try EVMSendClient(network:.filecoin,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"1")
            XCTFail("Fee budget must reject before signing")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
        let estimates=await transport.estimates
        XCTAssertEqual(estimates.count,1)
        XCTAssertTrue(estimates[0]["maxFeePerGas"].isNull)
        XCTAssertEqual(estimates[0]["value"].string,"0x0")
        XCTAssertTrue(estimates[0]["data"].string?.hasPrefix("0xa9059cbb") == true)
    }
    func testTestnetIdentityAndNoFeeCurrencyOracle() {
        XCTAssertEqual(EVMSendNetwork.filecoinCalibration.chainID,314159)
        XCTAssertTrue(EVMSendNetwork.filecoinCalibration.isTestnet)
        XCTAssertFalse(EVMSendNetwork.filecoin.isTestnet)
        XCTAssertEqual(EVMSendNetwork.filecoinCalibration.symbol,"FIL")
        XCTAssertNil(EVMSendNetwork.filecoin.oracle);XCTAssertNil(EVMSendNetwork.filecoinCalibration.oracle)
    }
    func testTokensNeverDeductTheirAmountToPayNativeGas() async throws {
        let client=try EVMSendClient(network:.filecoin,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.filecoin,nativeBalance:"0"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"123")
            XCTFail("Tokens cannot fund FIL gas")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
}

private actor FilecoinConcurrentTransport: AnkrTransport {
    let fixture = EVMSendFixtureTransport(network: .filecoin)
    var active = 0, peak = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return try await fixture.send(request)
    }
}

extension FilecoinSendTests {
    func testIndependentReadsOverlapWithinTheRequestBudget() async throws {
        let transport = FilecoinConcurrentTransport()
        let client = try EVMSendClient(network: .filecoin, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        _ = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
                                   recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)),
                                   reference: "native", decimals: 18, amount: "1000")
        let peak = await transport.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
    }
}

extension FilecoinSendTests {
    func testStatusRecoveryNeverRebroadcastsTerminalSends() async throws {
        for network in [EVMSendNetwork.filecoin, .filecoinCalibration] {
            let key = Data(repeating: 1, count: 32)
            let endpoint = URL(string: "https://fixture.example")!
            let builder = try EVMSendClient(network: network, endpoints: [endpoint], transport: EVMSendFixtureTransport(network: network))
            let plan = try await builder.quote(sender: EVMSendCrypto.address(privateKey: key), recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "123")
            let signed = try EVMSendCrypto.sign(plan, privateKey: key)
            for mode in ["confirmed", "failed", "cancelled", "replaced", "tampered", "unfinalized"] {
                let transport = EVMSendFixtureTransport(mode, network: network)
                await transport.configure(plan, signed)
                let client = try EVMSendClient(network: network, endpoints: [endpoint], transport: transport)
                if mode == "tampered" {
                    do { _ = try await client.status(signed, plan: plan); XCTFail("Altered receipt must be rejected") }
                    catch { XCTAssertNotNil(error as? EVMSendError) }
                } else {
                    let receipt = try await client.status(signed, plan: plan)
                    XCTAssertEqual(receipt.outcome.rawValue, mode == "unfinalized" ? "accepted" : mode)
                    let replay = try await client.submit(signed, plan: plan)
                    XCTAssertEqual(replay.outcome, receipt.outcome)
                }
                let counts = await transport.counts()
                XCTAssertEqual(counts.1, 0)
            }
        }
    }
}

extension FilecoinSendTests {
    func testLotusFeeVectorsAndLargeGasProductsAreExact() throws {
        // Reference: Lotus v1.37.0 chain/vm/burn_test.go.
        for (used,limit,burn) in [(100,200,90),(100,150,20),(1000,1300,60),(500,700,60),(200,200,0),(20000,21000,0),(0,2000,2000),(500,651,30),(500,5000,4500),(7_499_000_000,7_500_000_000,0),(3_750_000_000,7_500_000_000,3_375_000_000),(1,7_500_000_000,7_499_999_999)] as [(UInt64,UInt64,UInt64)] {
            XCTAssertEqual(try FilecoinSendFee.actual(gasUsed:used,gasLimit:limit,baseFee:1,feeCap:1,premium:0),used+burn)
        }
        for (used,limit,cap,premium,total) in [(100,110,11,1,1110),(100,130,11,1,1190),(100,110,10,1,1000),(100,110,6,1,600)] as [(UInt64,UInt64,UInt64,UInt64,UInt64)] {
            XCTAssertEqual(try FilecoinSendFee.actual(gasUsed:used,gasLimit:limit,baseFee:10,feeCap:cap,premium:premium),total)
        }
        XCTAssertThrowsError(try FilecoinSendFee.actual(gasUsed:11,gasLimit:10,baseFee:1,feeCap:2,premium:1))
        XCTAssertThrowsError(try FilecoinSendFee.actual(gasUsed:1,gasLimit:10_000_000_000,baseFee:1,feeCap:UInt64.max,premium:1))
    }
    func testLargeFilecoinGasAndDelegatedRecipients() async throws {
        let sender=try EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),to=try EVMSendCrypto.address(privateKey:Data(repeating:2,count:32))
        for network in [EVMSendNetwork.filecoin,.filecoinCalibration] {
            let alias=try FilecoinIdentity.delegated(to,testnet:network.isTestnet)
            let client=try EVMSendClient(network:network,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:network,gasEstimate:10_000_000))
            let plan=try await client.quote(sender:sender,recipient:alias,reference:"native",decimals:18,amount:"123")
            XCTAssertEqual(plan.recipient,to);XCTAssertEqual(plan.gasLimit,12_001_000)
            let signed=try EVMSendCrypto.sign(plan,privateKey:Data(repeating:1,count:32))
            try EVMSendCrypto.verify(signed,plan:plan)
            let settledTransport=EVMSendFixtureTransport("confirmed",network:network)
            await settledTransport.configure(plan,signed)
            let settled=try EVMSendClient(network:network,endpoints:[URL(string:"https://fixture.example")!],transport:settledTransport)
            let receipt=try await settled.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            XCTAssertGreaterThan(try XCTUnwrap(receipt.fee)/21_000,plan.maxFeePerGas)
            XCTAssertThrowsError(try network.address(FilecoinIdentity.delegated(to,testnet:!network.isTestnet)))
        }
    }
    func testPublicMainnetFeeQuotesWithoutSigning() async throws {
        guard ProcessInfo.processInfo.environment["OATH_FILECOIN_QUOTE_LIVE"]=="1",let path=ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in public mainnet quotes only") }
        let config=try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:path)),format:nil) as? [String:String])
        let key=try XCTUnwrap(config["AnkrAPIKey"])
        let sender="0xacaf41f4517c1d13f2817f67675099bbd5c93108",recipient="0x000000000000000000000000000000000000dead"
        for endpoint in [URL(string:"https://rpc.ankr.com/filecoin/"+key)!,URL(string:"https://api.node.glif.io/rpc/v1")!] {
            let client=try EVMSendClient(network:.filecoin,endpoints:[endpoint])
            for maximum in [false,true] {
                let plan=try await client.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"1000000000000000",maximum:maximum)
                XCTAssertGreaterThan(plan.gasLimit,21_000);XCTAssertGreaterThan(plan.fee,0)
                if maximum { XCTAssertEqual(plan.remaining,"0") } else { XCTAssertEqual(plan.amount,"1000000000000000") }
                try await client.preflight(plan)
            }
            let token=try await client.quote(sender:sender,recipient:recipient,reference:"0x60e1773636cf5e4a227d9ac24f20feca034ee25a",decimals:18,amount:"1")
            XCTAssertEqual(token.amount,"1");try await client.preflight(token)
        }
        let fallback=try EVMSendClient(network:.filecoin,endpoints:[URL(string:"https://rpc.ankr.com/filecoin/"+key)!,URL(string:"https://api.node.glif.io/rpc/v1")!],transport:FilecoinSendForcedFallback())
        let quote=try await fallback.quote(sender:sender,recipient:recipient,reference:"native",decimals:18,amount:"1")
        try await fallback.preflight(quote)
    }
}

private struct FilecoinSendForcedFallback: AnkrTransport {
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        if request.url?.host == "rpc.ankr.com" { return (Data(),503) }
        return try await AnkrHTTPTransport().send(request)
    }
}

private actor FilecoinNullRoundTransport: AnkrTransport {
    let fixture=EVMSendFixtureTransport("cancelled",network:.filecoin)
    var resolvedGap=false
    func configure(_ plan:EVMSendPlan,_ signed:EVMSignedSend) async { await fixture.configure(plan,signed) }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let calls=try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:XCTUnwrap(request.httpBody)).array)
        let (data,status)=try await fixture.send(request)
        let replies=try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:data).array)
        func object(_ value:SolanaJSON) throws -> [String:SolanaJSON] {
            guard case .object(let fields)=value else { throw EVMSendError.malformed };return fields
        }
        let changed=try replies.map { reply -> SolanaJSON in
            let call=try XCTUnwrap(calls.first { $0["id"]==reply["id"] }),params=call["params"].array ?? []
            var row=try object(reply)
            switch call["method"].string {
            case "eth_getBlockByNumber":
                if params[0].string=="finalized" {
                    var block=try object(XCTUnwrap(row["result"]));block["number"] = .string("0x6e");row["result"] = .object(block)
                }
            case "Filecoin.ChainGetTipSetByHeight":
                let epoch=try XCTUnwrap(params[0].integer)
                if epoch==105 { resolvedGap=true;row["result"] = .object(["Height":.number("104"),"Cids":.array([.object(["/":.string("fixture")])])]) }
            case "eth_getTransactionCount":
                let tag=try XCTUnwrap(params.last?.string),epoch=UInt64(tag.dropFirst(2),radix:16) ?? 0
                XCTAssertNotEqual(epoch,105,"Null epochs must be resolved before a state read")
                row["result"] = .string(epoch>=106 ? "0x8":"0x7")
            default: break
            }
            return .object(row)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(changed)),status)
    }
}
extension FilecoinSendTests {
    func testReplacementSearchSkipsNullEpochsWithoutGuessingCancellation() async throws {
        let key=Data(repeating:1,count:32),endpoint=URL(string:"https://fixture.example")!
        let builder=try EVMSendClient(network:.filecoin,endpoints:[endpoint],transport:EVMSendFixtureTransport(network:.filecoin))
        let plan=try await builder.quote(sender:EVMSendCrypto.address(privateKey:key),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
        let signed=try EVMSendCrypto.sign(plan,privateKey:key),transport=FilecoinNullRoundTransport()
        await transport.configure(plan,signed)
        let receipt=try await EVMSendClient(network:.filecoin,endpoints:[endpoint],transport:transport).status(signed,plan:plan)
        XCTAssertEqual(receipt.outcome,.cancelled)
        let gap=await transport.resolvedGap;XCTAssertTrue(gap)
        let counts=await transport.fixture.counts();XCTAssertEqual(counts.1,0)
    }
}

private actor FilecoinLookupFallbackTransport: AnkrTransport {
    let fixture:EVMSendFixtureTransport
    let missingEverywhere:Bool, fallbackUnavailable:Bool, wrongFallbackChain:Bool
    private(set) var fallbackReads=0
    init(network:EVMSendNetwork,missingEverywhere:Bool=false,fallbackUnavailable:Bool=false,wrongFallbackChain:Bool=false) {
        fixture=EVMSendFixtureTransport("confirmed",network:network)
        self.missingEverywhere=missingEverywhere;self.fallbackUnavailable=fallbackUnavailable;self.wrongFallbackChain=wrongFallbackChain
    }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        let fallback=request.url?.host=="fallback.example"
        if fallback { fallbackReads+=1 }
        if fallback,fallbackUnavailable { return (Data(),503) }
        let calls=try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:XCTUnwrap(request.httpBody)).array)
        let (data,status)=try await fixture.send(request)
        let replies=try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self,from:data).array)
        let changed=try replies.map { reply -> SolanaJSON in
            let call=try XCTUnwrap(calls.first { $0["id"]==reply["id"] })
            guard case .object(var row)=reply else { throw EVMSendError.malformed }
            if fallback,wrongFallbackChain,call["method"].string=="eth_chainId" { row["result"] = .string("0x1") }
            if !fallback || missingEverywhere,
               ["eth_getTransactionReceipt","eth_getTransactionByHash"].contains(call["method"].string ?? "") { row["result"] = .null }
            return .object(row)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(changed)),status)
    }
}

extension FilecoinSendTests {
    func testMissingHashIndexUsesVerifiedFallbackWithoutRebroadcasting() async throws {
        for network in [EVMSendNetwork.filecoin,.filecoinCalibration] {
            let key=Data(repeating:1,count:32),endpoints=[URL(string:"https://primary.example")!,URL(string:"https://fallback.example")!]
            let builder=try EVMSendClient(network:network,endpoints:[endpoints[0]],transport:EVMSendFixtureTransport(network:network))
            let plan=try await builder.quote(sender:EVMSendCrypto.address(privateKey:key),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"123")
            let signed=try EVMSendCrypto.sign(plan,privateKey:key)
            let transport=FilecoinLookupFallbackTransport(network:network)
            await transport.fixture.configure(plan,signed)
            let client=try EVMSendClient(network:network,endpoints:endpoints,transport:transport)
            let receipt=try await client.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            let replay=try await client.submit(signed,plan:plan);XCTAssertEqual(replay,receipt)
            let reads=await transport.fallbackReads;XCTAssertEqual(reads,4)
            let counts=await transport.fixture.counts();XCTAssertEqual(counts.1,0)
            for variant in 0..<3 {
                let unavailable=FilecoinLookupFallbackTransport(network:network,missingEverywhere:variant==0,fallbackUnavailable:variant==1,wrongFallbackChain:variant==2)
                await unavailable.fixture.configure(plan,signed)
                let missing=try EVMSendClient(network:network,endpoints:endpoints,transport:unavailable)
                for method in ["eth_getTransactionReceipt","eth_getTransactionByHash"] {
                    let result=try await missing.rpc(method,[.string(signed.hash)])
                    XCTAssertTrue(result.isNull,"An unavailable or wrong-chain fallback cannot prove a receipt")
                }
                let reads=await unavailable.fallbackReads;XCTAssertEqual(reads,2)
            }
        }
    }
}
