import XCTest
@testable import OathAnkr

private actor SuiConnectTransport: AnkrTransport {
    enum Mode:Sendable { case valid, wrongChain, failure, truncated, malformedAmount, changed, token }
    let mode:Mode
    var calls=0
    init(_ mode:Mode) { self.mode=mode }
    func send(_ request:URLRequest) async throws -> (Data,Int) {
        calls += 1
        let tokenType = "0x3::example::TEST"
        if mode == .token, let body = request.httpBody,
           String(decoding:body,as:UTF8.self).contains("coinMetadata") {
            return (try JSONSerialization.data(withJSONObject:["data":["chainIdentifier":SuiSendNetwork.testnet.chainIdentifier,
                "t0":["name":"Test Coin","symbol":"TEST","decimals":6]]]),200)
        }
        let owner = try SuiIdentity.address("0x2")
        let amount = mode == .malformedAmount ? "-" : mode == .changed && calls > 1 ? "2000000":"1000000"
        let value:[String:Any] = ["data":[
            "chainIdentifier":mode == .wrongChain ? SuiSendNetwork.mainnet.chainIdentifier:SuiSendNetwork.testnet.chainIdentifier,
            "epoch":["epochId":"100"],
            "simulateTransaction":["effects":["status":mode == .failure ? "FAILURE":"SUCCESS","executionError":["message":"Test execution rejected"],
                "gasEffects":["gasSummary":["computationCost":"1000","storageCost":"500","storageRebate":"100"]],
                "balanceChanges":["pageInfo":["hasNextPage":mode == .truncated],"nodes":[["owner":["address":owner],"coinType":["repr":mode == .token ? tokenType:"0x2::sui::SUI"],"amount":amount]]]
            ]]]]
        return (try JSONSerialization.data(withJSONObject:value),200)
    }
}
final class WalletConnectSuiReviewTests:XCTestCase {
    func testTokenPreviewRetainsExactAmountTypeAndDecimals() async throws {
        let client=try SuiSendClient(network:.testnet,transport:SuiConnectTransport(.token))
        let review=try await client.walletConnectReview(WalletConnectSuiTests().request())
        let reference=try SuiIdentity.reference("0x3::example::TEST")
        XCTAssertEqual(review.tokens[reference]?.decimals,6)
        XCTAssertEqual(review.tokens[reference]?.symbol,"TEST")
        XCTAssertTrue(review.changes[0].contains("1000000 atomic " + (try SuiIdentity.coinType(reference))))
        try await client.walletConnectPreflight(review)
    }
    func testLiveReviewUsesNetworkSimulationAndNativeUnits() async throws {
        let client=try SuiSendClient(network:.testnet,transport:SuiConnectTransport(.valid))
        let request=try WalletConnectSuiTests().request(),review=try await client.walletConnectReview(request)
        XCTAssertEqual(review.estimatedFee,1400)
        XCTAssertEqual(review.tokens["native"]?.decimals,9)
        XCTAssertEqual(review.changes.count,1)
        try await client.walletConnectPreflight(review)
    }
    func testWrongNetworkFailureTruncationAndMalformedAmountsRejected() async throws {
        for mode in [SuiConnectTransport.Mode.wrongChain,.failure,.truncated,.malformedAmount] {
            let client=try SuiSendClient(network:.testnet,transport:SuiConnectTransport(mode))
            do { _ = try await client.walletConnectReview(WalletConnectSuiTests().request()); XCTFail("Unsafe simulation accepted") } catch { XCTAssertTrue(error is SuiSendError) }
        }
    }
    func testChangedEffectsNeedNewApproval() async throws {
        let client=try SuiSendClient(network:.testnet,transport:SuiConnectTransport(.changed))
        let review=try await client.walletConnectReview(WalletConnectSuiTests().request())
        do { try await client.walletConnectPreflight(review); XCTFail("Changed effects accepted") } catch { XCTAssertEqual(error as? SuiSendError,.changed) }
    }
}
