import XCTest
@testable import OathAnkr

private struct IoTeXSendForcedFallback: AnkrTransport {
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        if request.url?.host == "rpc.ankr.com" { return (Data(), 503) }
        return try await AnkrHTTPTransport().send(request)
    }
}

extension IoTeXSendTests {
    func testPublicMainnetQuotesAndIndependentFallbackWithoutSigning() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_QUOTE_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"] else { throw XCTSkip("Opt-in read-only IoTeX quotes") }
        let config = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path)), format: nil) as? [String: String])
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let endpoints = [URL(string: "https://rpc.ankr.com/iotex/" + key)!, URL(string: "https://babel-api.mainnet.iotex.io")!]
        let sender = "0xcf3aad8dc49158fd15b59a6dae41f1f52236aef3", recipient = "0x000000000000000000000000000000000000dead"
        for index in 0..<3 {
            let client = try EVMSendClient(network: .iotex, endpoints: index == 1 ? [endpoints[1]] : endpoints,
                transport: index == 2 ? IoTeXSendForcedFallback() : AnkrHTTPTransport())
            for maximum in [false, true] {
                print("IOTEX_QUOTE provider=\(index) maximum=\(maximum)")
                let plan = try await client.quote(sender: sender, recipient: recipient, reference: "native", decimals: 18, amount: "1000000000000000", maximum: maximum)
                XCTAssertGreaterThan(plan.fee, 0)
                if maximum { XCTAssertEqual(plan.remaining, "0") } else { XCTAssertEqual(plan.amount, "1000000000000000") }
                try await client.preflight(plan)
            }
            print("IOTEX_QUOTE provider=\(index) token")
            let token = try await client.quote(sender: sender, recipient: recipient, reference: "0xa00744882684c3e4747faefd68d283ea44099d03", decimals: 18, amount: "1")
            XCTAssertEqual(token.amount, "1"); try await client.preflight(token)
        }
    }
}

@MainActor final class IoTeXSendTests: XCTestCase {
    func testIoTeXUsesPriorityRecommendationWhenGasPriceEqualsBaseFee() async throws {
        for network in [EVMSendNetwork.iotex, .iotexTestnet] {
            for maximum in [false, true] {
                let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!],
                                              transport: IoTeXPriorityTransport(network: network))
                let plan = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
                    recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18,
                    amount: "1000", maximum: maximum)
                XCTAssertEqual(plan.maxPriorityFeePerGas, 1_000_000_000_000)
                XCTAssertEqual(plan.maxFeePerGas, 3_000_000_000_000)
                if maximum { XCTAssertEqual(plan.remaining, "0") } else { XCTAssertEqual(plan.amount, "1000") }
                try await client.preflight(plan)
            }
        }
    }
    func testUnusablePriorityRecommendationCannotReachSigning() async throws {
        for priority in [UInt64(0), 100_000_000_000_001] {
            let client = try EVMSendClient(network: .iotex, endpoints: [URL(string: "https://fixture.example")!],
                                          transport: IoTeXPriorityTransport(network: .iotex, priority: priority))
            do {
                _ = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
                    recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "1000")
                XCTFail("Unusable fee recommendation must not produce a plan")
            } catch { XCTAssertEqual(error as? EVMSendError, priority == 0 ? .changed : .feeTooHigh) }
        }
    }
    func testSignaturesMatchIndependentMainnetAndTestnetVectors() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/IoTeXSend"))
        let vectors = try JSONDecoder().decode([EVMSendTests.Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 8)
        for vector in vectors {
            let plan = EVMSendPlan(network: vector.network, sender: vector.sender, recipient: vector.recipient, reference: vector.reference,
                decimals: vector.decimals, requestedAmount: vector.amount, amount: vector.amount,
                assetBalance: "1000000000000000000000", nativeBalance: "1000000000000000000000", nonce: 7,
                gasLimit: vector.reference == "native" ? 10_000 : 70_000, maxFeePerGas: 41_000_000_000,
                maxPriorityFeePerGas: vector.legacy ? 0 : 1_000_000_000, blockHeight: 100, legacy: vector.legacy)
            let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
            XCTAssertEqual(TronSendCrypto.hex(signed.bytes), vector.raw)
            XCTAssertEqual(signed.hash, vector.hash)
            try EVMSendCrypto.verify(signed, plan: plan)
            var changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
            changed["network"] = plan.network == .iotex ? "iotexTestnet" : "iotex"
            let otherChain = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: changed))
            XCTAssertThrowsError(try EVMSendCrypto.verify(signed, plan: otherChain))
        }
    }
    func testRemainingBalancePaysFirstAndOnlyShortfallReducesPayment() async throws {
        for network in [EVMSendNetwork.iotex, .iotexTestnet] {
            let balance="1000000000000000000",fee:UInt64=410000000000000
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
        let client=try EVMSendClient(network:.iotex,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.iotex,nativeBalance:"410000000000000"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
            XCTFail("The gas budget leaves no positive payment")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testTokenFeeShortageIsDetectedBeforeFinalSimulation() async throws {
        let transport=EVMSendFixtureTransport("celoTokenAffordability",network:.iotex,nativeBalance:"1000000000000000",gasEstimate:60_000)
        let client=try EVMSendClient(network:.iotex,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
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
        XCTAssertEqual(EVMSendNetwork.iotexTestnet.chainID,4690)
        XCTAssertEqual(EVMSendNetwork.iotex.chainID,4689)
        XCTAssertFalse(EVMSendNetwork.iotexTestnet.isSei)
        XCTAssertFalse(EVMSendNetwork.iotex.isSei)
        XCTAssertTrue(EVMSendNetwork.iotexTestnet.isTestnet)
        XCTAssertFalse(EVMSendNetwork.iotex.isTestnet)
        XCTAssertEqual(EVMSendNetwork.iotexTestnet.symbol,"IOTX")
        XCTAssertNil(EVMSendNetwork.iotex.oracle);XCTAssertNil(EVMSendNetwork.iotexTestnet.oracle)
    }
    func testTokensNeverDeductTheirAmountToPayNativeGas() async throws {
        let client=try EVMSendClient(network:.iotex,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.iotex,nativeBalance:"0"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"123")
            XCTFail("Tokens cannot fund IOTX gas")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
}

private struct IoTeXPriorityTransport: AnkrTransport {
    let fixture: EVMSendFixtureTransport
    let priority: UInt64
    init(network: EVMSendNetwork, priority: UInt64 = 1_000_000_000_000) {
        fixture = EVMSendFixtureTransport(network: network); self.priority = priority
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array)
        let (data, status) = try await fixture.send(request)
        let replies = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
        let changed = try replies.map { reply -> SolanaJSON in
            let call = try XCTUnwrap(calls.first { $0["id"] == reply["id"] })
            guard case .object(var row) = reply else { throw EVMSendError.malformed }
            switch call["method"].string {
            case "eth_gasPrice": row["result"] = .string("0xe8d4a51000")
            case "eth_maxPriorityFeePerGas": row["result"] = .string("0x" + String(priority, radix: 16))
            case "eth_getBlockByNumber":
                guard case .object(var block) = row["result"] else { throw EVMSendError.malformed }
                block["baseFeePerGas"] = .string("0xe8d4a51000"); row["result"] = .object(block)
            default: break
            }
            return .object(row)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(changed)), status)
    }
}

private actor IoTeXConcurrentTransport: AnkrTransport {
    let fixture = EVMSendFixtureTransport(network: .iotex)
    var active = 0, peak = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return try await fixture.send(request)
    }
}

extension IoTeXSendTests {
    func testIndependentReadsOverlapWithinTheRequestBudget() async throws {
        let transport = IoTeXConcurrentTransport()
        let client = try EVMSendClient(network: .iotex, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        _ = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
                                   recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)),
                                   reference: "native", decimals: 18, amount: "1000")
        let peak = await transport.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
    }
}

extension IoTeXSendTests {
    func testStatusRecoveryNeverRebroadcastsTerminalSends() async throws {
        for network in [EVMSendNetwork.iotex, .iotexTestnet] {
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

private actor IoTeXLookupFallbackTransport: AnkrTransport {
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

extension IoTeXSendTests {
    func testMissingHashIndexUsesVerifiedFallbackWithoutRebroadcasting() async throws {
        for network in [EVMSendNetwork.iotex,.iotexTestnet] {
            let key=Data(repeating:1,count:32),endpoints=[URL(string:"https://primary.example")!,URL(string:"https://fallback.example")!]
            let builder=try EVMSendClient(network:network,endpoints:[endpoints[0]],transport:EVMSendFixtureTransport(network:network))
            let plan=try await builder.quote(sender:EVMSendCrypto.address(privateKey:key),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"123")
            let signed=try EVMSendCrypto.sign(plan,privateKey:key)
            let transport=IoTeXLookupFallbackTransport(network:network)
            await transport.fixture.configure(plan,signed)
            let client=try EVMSendClient(network:network,endpoints:endpoints,transport:transport)
            let receipt=try await client.status(signed,plan:plan)
            XCTAssertEqual(receipt.outcome,.confirmed)
            let replay=try await client.submit(signed,plan:plan);XCTAssertEqual(replay,receipt)
            let reads=await transport.fallbackReads;XCTAssertEqual(reads,4)
            let counts=await transport.fixture.counts();XCTAssertEqual(counts.1,0)
            for variant in 0..<3 {
                let unavailable=IoTeXLookupFallbackTransport(network:network,missingEverywhere:variant==0,fallbackUnavailable:variant==1,wrongFallbackChain:variant==2)
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

private actor IoTeXLaggingHeadTransport: AnkrTransport {
    let fixture = EVMSendFixtureTransport(network: .iotex)
    let unavailableBoundary: Bool
    var boundaryReads = 0
    init(unavailableBoundary: Bool = false) { self.unavailableBoundary = unavailableBoundary }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array)
        let (data, status) = try await fixture.send(request)
        let rows = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
        let replies = try rows.map { row -> SolanaJSON in
            let call = try XCTUnwrap(calls.first { $0["id"] == row["id"] })
            guard call["method"].string == "eth_getBlockByNumber",
                  case .object(var reply) = row, case .object(var block) = row["result"] else { return row }
            let latest = call["params"].array?.first?.string == "latest"
            if !latest { boundaryReads += 1 }
            if latest || unavailableBoundary { block["number"] = .string("0x64") }
            reply["result"] = .object(block)
            return .object(reply)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(replies)), status)
    }
}

extension IoTeXSendTests {
    func testPostReceiptBalanceUsesExplicitBlockWhenLatestReplicaLags() async throws {
        let endpoint = URL(string: "https://fixture.example")!
        let builder = try EVMSendClient(network: .iotex, endpoints: [endpoint], transport: EVMSendFixtureTransport(network: .iotex))
        let plan = try await builder.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
            recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "123")
        let transport = IoTeXLaggingHeadTransport()
        let client = try EVMSendClient(network: .iotex, endpoints: [endpoint], transport: transport)
        let balance = try await client.balancesAfter(plan, minimumHeight: 101)
        XCTAssertEqual(balance.height, 101)
        let reads = await transport.boundaryReads
        XCTAssertEqual(reads, 2, "Explicit boundary must also pass the block-hash recheck")
        let unavailable = try EVMSendClient(network: .iotex, endpoints: [endpoint], transport: IoTeXLaggingHeadTransport(unavailableBoundary: true))
        do { _ = try await unavailable.balancesAfter(plan, minimumHeight: 101); XCTFail("Never accept a pre-receipt balance") }
        catch { XCTAssertEqual(error as? EVMSendError, .changed) }
    }
}

private actor IoTeXEnvelopeTransport: AnkrTransport {
    let fixture: EVMSendFixtureTransport
    let receiptStatus: UInt64?
    let failPrimary: Bool
    var fallbackCalls = 0
    init(receiptStatus: UInt64? = nil, failPrimary: Bool = false) {
        self.receiptStatus = receiptStatus; self.failPrimary = failPrimary
        fixture = EVMSendFixtureTransport("confirmed", network: .iotex)
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let fallback = request.url?.host == "fallback.example"
        if fallback { fallbackCalls += 1 }
        let payload = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        guard let calls = payload.array else { return try await fixture.send(request) }
        let (data, status) = try await fixture.send(request)
        let rows = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
        let replies = try rows.map { row -> SolanaJSON in
            let call = try XCTUnwrap(calls.first { $0["id"] == row["id"] })
            guard case .object(var reply) = row else { throw EVMSendError.malformed }
            if failPrimary, !fallback, call["method"].string != "eth_chainId" {
                reply.removeValue(forKey: "result")
                reply["error"] = .object(["code":.number("13"), "message":.string("state unavailable")])
            } else if let receiptStatus, call["method"].string == "eth_getTransactionReceipt", case .object(var receipt) = row["result"] {
                receipt["status"] = .string("0x" + String(receiptStatus, radix:16))
                reply["result"] = .object(receipt)
            }
            return .object(reply)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(replies)),status)
    }
}

extension IoTeXSendTests {
    func testNativeAddressAliasesUseTheSameReviewedRecipient() async throws {
        let from = try EVMSendCrypto.address(privateKey: Data(repeating:1,count:32))
        let to = try EVMSendCrypto.address(privateKey: Data(repeating:2,count:32))
        for network in [EVMSendNetwork.iotex, .iotexTestnet] {
            let client = try EVMSendClient(network:network,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:network))
            let plan = try await client.quote(sender:IoTeXIdentity.native(from),recipient:IoTeXIdentity.native(to),reference:"native",decimals:18,amount:"1")
            XCTAssertEqual(plan.sender,from); XCTAssertEqual(plan.recipient,to)
            XCTAssertEqual(plan.gasLimit,10_000)
            XCTAssertThrowsError(try network.address(String(try IoTeXIdentity.native(to).dropLast()) + "!"))
        }
    }
    func testNativeFailureCodesSettleAsFailedAndNeverRebroadcast() async throws {
        let key = Data(repeating:1,count:32), endpoint = URL(string:"https://fixture.example")!
        let builder = try EVMSendClient(network:.iotex,endpoints:[endpoint],transport:EVMSendFixtureTransport(network:.iotex))
        let plan = try await builder.quote(sender:EVMSendCrypto.address(privateKey:key),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
        let signed = try EVMSendCrypto.sign(plan,privateKey:key)
        for code: UInt64 in [0,100,101,106,116,200,215,999] {
            let transport = IoTeXEnvelopeTransport(receiptStatus:code)
            await transport.fixture.configure(plan,signed)
            let client = try EVMSendClient(network:.iotex,endpoints:[endpoint],transport:transport)
            if code == 999 {
                do { _ = try await client.status(signed,plan:plan); XCTFail("Unknown status must not settle") }
                catch { XCTAssertEqual(error as? EVMSendError,.malformed) }
            } else {
                let receipt = try await client.submit(signed,plan:plan)
                XCTAssertEqual(receipt.outcome,.failed)
                XCTAssertEqual(receipt.fee,200_000_000_000_000)
            }
            let counts = await transport.fixture.counts(); XCTAssertEqual(counts.1,0)
        }
    }
    func testStateUnavailableFallbackNeverRetriesBroadcast() async throws {
        let endpoints = [URL(string:"https://primary.example")!,URL(string:"https://fallback.example")!]
        let transport = IoTeXEnvelopeTransport(failPrimary:true)
        let client = try EVMSendClient(network:.iotex,endpoints:endpoints,transport:transport)
        let value = try await client.balance(owner:"0x"+String(repeating:"1",count:40),reference:"native")
        XCTAssertEqual(value,"1000000000000000000000")
        let before = await transport.fallbackCalls
        do { _ = try await client.rpc("eth_sendRawTransaction",[.string("0x00")]); XCTFail("Ambiguous broadcast must reconcile before retry") }
        catch { XCTAssertEqual(error as? EVMSendError,.rpc(13)) }
        let after = await transport.fallbackCalls
        XCTAssertEqual(before,1); XCTAssertEqual(after,before)
    }
}
