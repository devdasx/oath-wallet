import XCTest
@testable import OathAnkr

@MainActor final class ChilizSendTests: XCTestCase {
    func testRemainingBalancePaysFirstAndOnlyShortfallReducesPayment() async throws {
        for network in [EVMSendNetwork.chiliz, .chilizSpicy] {
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
        let client=try EVMSendClient(network:.chiliz,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.chiliz,nativeBalance:"861000000000000"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
            XCTFail("The gas budget leaves no positive payment")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testTokenFeeShortageIsDetectedBeforeFinalSimulation() async throws {
        let transport=EVMSendFixtureTransport("celoTokenAffordability",network:.chiliz,nativeBalance:"1000000000000000",gasEstimate:60_000)
        let client=try EVMSendClient(network:.chiliz,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
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
        XCTAssertEqual(EVMSendNetwork.chilizSpicy.chainID,88882)
        XCTAssertTrue(EVMSendNetwork.chilizSpicy.isTestnet)
        XCTAssertFalse(EVMSendNetwork.chiliz.isTestnet)
        XCTAssertEqual(EVMSendNetwork.chilizSpicy.symbol,"CHZ")
        XCTAssertNil(EVMSendNetwork.chiliz.oracle);XCTAssertNil(EVMSendNetwork.chilizSpicy.oracle)
    }
    func testTokensNeverDeductTheirAmountToPayNativeGas() async throws {
        let client=try EVMSendClient(network:.chiliz,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.chiliz,nativeBalance:"0"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"123")
            XCTFail("Tokens cannot fund CHZ gas")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
}

private actor ChilizConcurrentTransport: AnkrTransport {
    let fixture = EVMSendFixtureTransport(network: .chiliz)
    var active = 0, peak = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        return try await fixture.send(request)
    }
}

extension ChilizSendTests {
    func testIndependentReadsOverlapWithinTheRequestBudget() async throws {
        let transport = ChilizConcurrentTransport()
        let client = try EVMSendClient(network: .chiliz, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
        _ = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)),
                                   recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)),
                                   reference: "native", decimals: 18, amount: "1000")
        let peak = await transport.peak
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 4)
    }
}

extension ChilizSendTests {
    func testStatusRecoveryNeverRebroadcastsTerminalSends() async throws {
        for network in [EVMSendNetwork.chiliz, .chilizSpicy] {
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
