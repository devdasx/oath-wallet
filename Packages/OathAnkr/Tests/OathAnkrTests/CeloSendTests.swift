import XCTest
@testable import OathAnkr

@MainActor final class CeloSendTests: XCTestCase {
    func testRemainingBalancePaysFirstAndOnlyShortfallReducesPayment() async throws {
        for network in [EVMSendNetwork.celo, .celoSepolia] {
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
        let client=try EVMSendClient(network:.celo,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.celo,nativeBalance:"861000000000000"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"native",decimals:18,amount:"1")
            XCTFail("The gas budget leaves no positive payment")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
    func testTokenFeeShortageIsDetectedBeforeFinalSimulation() async throws {
        let transport=EVMSendFixtureTransport("celoTokenAffordability",network:.celo,nativeBalance:"1000000000000000",gasEstimate:60_000)
        let client=try EVMSendClient(network:.celo,endpoints:[URL(string:"https://fixture.example")!],transport:transport)
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
        XCTAssertEqual(EVMSendNetwork.celoSepolia.chainID,11142220)
        XCTAssertTrue(EVMSendNetwork.celoSepolia.isTestnet)
        XCTAssertFalse(EVMSendNetwork.celo.isTestnet)
        XCTAssertEqual(EVMSendNetwork.celoSepolia.symbol,"CELO")
        XCTAssertNil(EVMSendNetwork.celo.oracle);XCTAssertNil(EVMSendNetwork.celoSepolia.oracle)
    }
    func testTokensNeverDeductTheirAmountToPayNativeGas() async throws {
        let client=try EVMSendClient(network:.celo,endpoints:[URL(string:"https://fixture.example")!],transport:EVMSendFixtureTransport(network:.celo,nativeBalance:"0"))
        do {
            _ = try await client.quote(sender:EVMSendCrypto.address(privateKey:Data(repeating:1,count:32)),recipient:EVMSendCrypto.address(privateKey:Data(repeating:2,count:32)),reference:"0x"+String(repeating:"3",count:40),decimals:6,amount:"123")
            XCTFail("Tokens cannot fund CELO gas")
        } catch { XCTAssertEqual(error as? SendFeeFundingError,.insufficientNativeBalance) }
    }
}
