import XCTest
@testable import OathAnkr

private struct SeiSendForcedFallback: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "rpc.ankr.com" { return (Data(), 503) }
        return try await AnkrHTTPTransport().send(request)
    }
}

extension SeiSendTests {
    func testPublicMainnetQuotesAndIndependentFallbackWithoutSigning() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SEI_QUOTE_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in read-only Sei quotes") }
        let config = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let endpoints = [URL(string: "https://rpc.ankr.com/sei_evm/" + key)!, URL(string: "https://evm-rpc.sei-apis.com")!]
        let sender = "0x726b000328edc9ee56fa125b24c29b0e62b7b28b", recipient = "0x000000000000000000000000000000000000dead"
        for index in 0..<3 {
            let client = try EVMSendClient(network: .sei, endpoints: index == 2 ? endpoints : [endpoints[index]],
                transport: index == 2 ? SeiSendForcedFallback() : AnkrHTTPTransport())
            for maximum in [false, true] {
                let plan = try await client.quote(sender: sender, recipient: recipient, reference: "native", decimals: 18, amount: "1000000000000000", maximum: maximum)
                XCTAssertGreaterThan(plan.fee, 0)
                if maximum { XCTAssertEqual(plan.remaining, "0") } else { XCTAssertEqual(plan.amount, "1000000000000000") }
                try await client.preflight(plan)
            }
            let token = try await client.quote(sender: sender, recipient: recipient, reference: "0xe15fc38f6d8c56af07bbcbe3baf5708a2bf42392", decimals: 6, amount: "1")
            XCTAssertEqual(token.amount, "1"); try await client.preflight(token)
        }
    }
}

@MainActor final class SeiSendTests: XCTestCase {
    func testSignaturesMatchIndependentMainnetAndTestnetVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/SeiSend"))
        let vectors = try JSONDecoder().decode([EVMSendTests.Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 8)
        for vector in vectors {
            let plan = EVMSendPlan(network: vector.network, sender: vector.sender, recipient: vector.recipient, reference: vector.reference,
                decimals: vector.decimals, requestedAmount: vector.amount, amount: vector.amount,
                assetBalance: "1000000000000000000000", nativeBalance: "1000000000000000000000", nonce: 7,
                gasLimit: vector.reference == "native" ? 21_000 : 70_000, maxFeePerGas: 41_000_000_000,
                maxPriorityFeePerGas: vector.legacy ? 0 : 1_000_000_000, blockHeight: 100, legacy: vector.legacy)
            let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
            XCTAssertEqual(TronSendCrypto.hex(signed.bytes), vector.raw)
            XCTAssertEqual(signed.hash, vector.hash)
            try EVMSendCrypto.verify(signed, plan: plan)
            var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
            changed["network"] = plan.network == .sei ? "seiTestnet" : "sei"
            let otherChain = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try EVMSendCrypto.verify(signed, plan: otherChain))
        }
    }
    func testRemainingBalancePaysFirstAndOnlyShortfallReducesPayment() async throws {
        for network in [EVMSendNetwork.sei, .seiTestnet] {
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
        let client=try EVMSendClient(network:.sei,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.sei,nativeBalance:"861000000000000"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
            XCTFail("The gas budget leaves no positive payment")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testTokenFeeShortageIsDetectedBeforeFinalSimulation() async throws {
        let transport=EVMSendFixtureTransport("celoTokenAffordability",network:.sei,nativeBalance:"1000000000000000",gasEstimate:60_000)
        let client=try EVMSendClient(network:.sei,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
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
        XCTAssertEqual(EVMSendNetwork.seiTestnet.chainID,1328)
        XCTAssertTrue(EVMSendNetwork.seiTestnet.isTestnet)
        XCTAssertFalse(EVMSendNetwork.sei.isTestnet)
        XCTAssertEqual(EVMSendNetwork.seiTestnet.symbol,"SEI")
        XCTAssertNil(EVMSendNetwork.sei.oracle);XCTAssertNil(EVMSendNetwork.seiTestnet.oracle)
    }
    func testTokensNeverDeductTheirAmountToPayNativeGas() async throws {
        let client=try EVMSendClient(network:.sei,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.sei,nativeBalance:"0"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"123")
            XCTFail("Tokens cannot fund SEI gas")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
}

private actor SeiConcurrentTransport: AnkrTransport {
    let fixture = EVMSendFixtureTransport(network: .sei)
    var active = 0, peak = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return try await fixture.send(request)
    }
}

extension SeiSendTests {
    func testIndependentReadsOverlapWithinTheRequestBudget() async throws {
        let transport = SeiConcurrentTransport()
        let client = try EVMSendClient(network: .sei, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        _ = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
                                   recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)),
                                   reference: "native", decimals: 18, amount: "1000")
        let peak = await transport.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
    }
}

extension SeiSendTests {
    func testStatusRecoveryNeverRebroadcastsTerminalSends() async throws {
        for network in [EVMSendNetwork.sei, .seiTestnet] {
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

private actor SeiLookupFallbackTransport: AnkrTransport {
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

extension SeiSendTests {
    func testMissingHashIndexUsesVerifiedFallbackWithoutRebroadcasting() async throws {
        for network in [EVMSendNetwork.sei,.seiTestnet] {
            let key=Data(repeating:1,count:32),endpoints=[URL(string:"https://primary.example")!,URL(string:"https://fallback.example")!]
            let builder=try EVMSendClient(network:network,endpoints:[endpoints[0]],transport:EVMSendFixtureTransport(network:network))
            let plan=try await builder.quote(sender:EVMSendCrypto.address(privateKey:key),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"123")
            let signed=try EVMSendCrypto.sign(plan,privateKey:key)
            let transport=SeiLookupFallbackTransport(network:network)
            await transport.fixture.configure(plan,signed)
            let client=try EVMSendClient(network:network,endpoints:endpoints,transport:transport)
            let receipt=try await client.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            let replay=try await client.submit(signed,plan:plan);XCTAssertEqual(replay,receipt)
            let reads=await transport.fallbackReads;XCTAssertEqual(reads,4)
            let counts=await transport.fixture.counts();XCTAssertEqual(counts.1,0)
            for variant in 0..<3 {
                let unavailable=SeiLookupFallbackTransport(network:network,missingEverywhere:variant==0,fallbackUnavailable:variant==1,wrongFallbackChain:variant==2)
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
