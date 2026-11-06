import XCTest
@testable import OathAnkr

@MainActor final class CronosSendTests: XCTestCase {
    func testTrackedContractIdentityIsChainSpecificAndWrappedCROIsAToken() throws {
        let contract = "0x5c7F8A570d578ED84E63fdFA7b1eE72dEae1AE23"
        XCTAssertEqual(try TokenDiscoveryNetworks.canonical(contract, network: "cronos"), contract.lowercased())
        XCTAssertFalse(TokenDiscoveryNetworks.isNativeRepresentation(contract, network: "cronos"))
        XCTAssertThrowsError(try TokenDiscoveryNetworks.canonical("cro1invalid", network: "cronos"))
        XCTAssertThrowsError(try TokenDiscoveryNetworks.canonical(contract, network: "cronosTestnet"))
    }
    func testRemainingBalancePaysFirstAndOnlyShortfallReducesPayment() async throws {
        for network in [EVMSendNetwork.cronos, .cronosTestnet] {
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
    func testProviderMismatchMalformedAndUnfundedPlansNeverBroadcast() async throws {
        for network in [EVMSendNetwork.cronos, .cronosTestnet] {
            for mode in ["wrongChain", "duplicateID", "empty", "expensive", "gasOverflow", "rpcError", "decimals", "falseToken"] {
                let transport = EVMSendFixtureTransport(mode, network: network)
                let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
                let token = ["decimals", "falseToken"].contains(mode)
                do {
                    _ = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)), recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: token ? "0x" + String(repeating: "3", count: 40) : "native", decimals: token ? 6 : 18, amount: "1")
                    XCTFail("Rejected fixture must not produce a signable plan: " + mode)
                } catch { }
                let counts = await transport.counts(); XCTAssertEqual(counts.1, 0)
            }
        }
    }
    func testFailedTamperedAndReplacedReceiptsNeverReplayPayment() async throws {
        for network in [EVMSendNetwork.cronos, .cronosTestnet] {
            let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: EVMSendFixtureTransport(network: network))
            let plan = try await client.quote(sender: EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32)), recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "1")
            let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
            for mode in ["confirmed", "failed", "tampered", "replaced", "cancelled"] {
                let transport = EVMSendFixtureTransport(mode, network: network)
                await transport.configure(plan, signed)
                let recovery = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
                if mode == "tampered" {
                    do { _ = try await recovery.status(signed, plan: plan); XCTFail("Tampered receipt") } catch { }
                } else {
                    let result = try await recovery.submit(signed, plan: plan)
                    XCTAssertEqual(result.outcome.rawValue, mode)
                }
                let counts = await transport.counts(); XCTAssertEqual(counts.1, 0)
            }
        }
    }
    func testExactFeeBudgetCannotBecomeAZeroValuePayment() async throws {
        let client=try EVMSendClient(network:.cronos,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.cronos,nativeBalance:"861000000000000"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
            XCTFail("The gas budget leaves no positive payment")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testTokenFeeShortageIsDetectedBeforeFinalSimulation() async throws {
        let transport=EVMSendFixtureTransport("celoTokenAffordability",network:.cronos,nativeBalance:"1000000000000000",gasEstimate:60_000)
        let client=try EVMSendClient(network:.cronos,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
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
        XCTAssertEqual(EVMSendNetwork.cronosTestnet.chainID,338)
        XCTAssertTrue(EVMSendNetwork.cronosTestnet.isTestnet)
        XCTAssertFalse(EVMSendNetwork.cronos.isTestnet)
        XCTAssertEqual(EVMSendNetwork.cronosTestnet.symbol,"TCRO")
        XCTAssertNil(EVMSendNetwork.cronos.oracle);XCTAssertNil(EVMSendNetwork.cronosTestnet.oracle)
    }
    func testTokensNeverDeductTheirAmountToPayNativeGas() async throws {
        let client=try EVMSendClient(network:.cronos,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.cronos,nativeBalance:"0"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"123")
            XCTFail("Tokens cannot fund CRO gas")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
}
