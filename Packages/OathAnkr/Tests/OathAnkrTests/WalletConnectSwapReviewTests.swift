import XCTest
@testable import OathAnkr

final class WalletConnectSwapReviewTests: XCTestCase {
    private let owner = "0x4444444444444444444444444444444444444444"
    private let router = "0x65b382653f7c31bc0af67f188122035461ec9c76"
    private let a = "0x1111111111111111111111111111111111111111"
    private let c = "0x3333333333333333333333333333333333333333"
    private func request(_ name: String, chain: UInt64 = 1, to: String? = nil, value: String = "0x0") throws -> WalletConnectEVMRequest {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "call-details", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        let vectors = try JSONDecoder().decode([WalletConnectCallDetailsTests.Vector].self, from: Data(contentsOf: file))
        let data = try XCTUnwrap(vectors.first { $0.name == name }).data
        return try .init(params: JSONSerialization.data(withJSONObject: [["from": owner, "to": to ?? router, "data": data, "value": value]]), account: owner, chainID: chain)
    }
    func testPrimaryReviewRecognizesUniversalSwapsDespiteLegacyClassification() throws {
        for name in ["v3-exact-in", "v3-exact-out", "v2-exact-in", "v2-exact-out"] {
            let request = try request(name)
            XCTAssertEqual(WalletConnectEVMAction(request).kind, .contract) // original UI bug
            let review = WalletConnectSwapReview(request), route = try XCTUnwrap(review.routes.first)
            XCTAssertEqual(review.chainID, 1)
            XCTAssertFalse(review.incomplete)
            XCTAssertEqual(route.input.reference, a)
            XCTAssertEqual(route.output.reference, c)
            XCTAssertEqual(route.input.amount, "123456789")
            XCTAssertEqual(route.output.amount, "100000000")
            XCTAssertEqual(route.input.bound, name.contains("out") ? .maximum : .exact)
            XCTAssertEqual(route.output.bound, name.contains("out") ? .exact : .minimum)
            XCTAssertEqual(route.recipient, owner)
        }
    }
    func testPrimaryReviewRetainsEveryCommandIncludingFoldedAndUnknownOperations() throws {
        for name in ["token-native", "native-token", "nested-swap-sweep", "optional-nested", "unknown-and-sweep", "permit-transfer", "wrap-transfer", "partial-native"] {
            let input = try request(name, value: name == "native-token" ? "0x75bcd15" : "0x0")
            let details = WalletConnectCallDetails(input), review = WalletConnectSwapReview(input)
            XCTAssertFalse(review.operations.isEmpty, name)
            XCTAssertEqual(review.operations, details.steps, name)
            XCTAssertEqual(review.deadline, details.deadline, name)
        }
        let transfer = WalletConnectSwapReview(try request("permit-transfer"))
        XCTAssertTrue(transfer.routes.isEmpty)
        XCTAssertEqual(transfer.operations.first?.values.first(where: { $0.label == .owner })?.value, owner)
        let routerTransfer = WalletConnectSwapReview(try request("wrap-transfer"))
        XCTAssertEqual(routerTransfer.operations.last?.values.first(where: { $0.label == .owner })?.value, router)
        XCTAssertEqual(routerTransfer.operations.last?.values.first(where: { $0.label == .amount })?.routerBalance, true)
    }
    func testNativeBoundariesRetainCorrectAmountsAndRecipient() throws {
        let outgoing = WalletConnectSwapReview(try request("token-native"))
        XCTAssertEqual(outgoing.routes[0].input.reference, a)
        XCTAssertEqual(outgoing.routes[0].output.reference, "native")
        XCTAssertEqual(outgoing.routes[0].output.amount, "90000000")
        XCTAssertEqual(outgoing.routes[0].output.bound, .minimum)
        XCTAssertEqual(outgoing.routes[0].recipient, owner)
        XCTAssertTrue(outgoing.nativeConversions.isEmpty)
        let incoming = WalletConnectSwapReview(try request("native-token", value: "0x75bcd15"))
        XCTAssertEqual(incoming.routes[0].input.reference, "native")
        XCTAssertEqual(incoming.routes[0].input.bound, .maximum)
        XCTAssertEqual(incoming.routes[0].input.amount, "123456789")
        XCTAssertEqual(incoming.routes[0].output.reference, c)
        XCTAssertTrue(incoming.nativeConversions.isEmpty)
    }
    func testNeverMistakesWrappedTokensOrUnrelatedConversionsForNativeOutput() throws {
        for name in ["unrelated-unwrap", "unwrap-wrong-order", "unwrap-wrong-recipient", "optional-native", "partial-native"] {
            let review = WalletConnectSwapReview(try request(name))
            XCTAssertNotEqual(review.routes[0].output.reference, "native", name)
            XCTAssertFalse(review.nativeConversions.isEmpty, name)
        }
        XCTAssertNotEqual(WalletConnectSwapReview(try request("wrapped-token")).routes[0].input.reference, "native")
        XCTAssertNotEqual(WalletConnectSwapReview(try request("native-token", value: "0x1")).routes[0].input.reference, "native")
        XCTAssertTrue(WalletConnectSwapReview(try request("partial-native")).incomplete)
        XCTAssertTrue(WalletConnectSwapReview(try request("optional-native")).routes[0].optional)
    }
    func testSplitRoutesKeepSeparateBoundsAndRouterBalanceIsNotAnAmount() throws {
        let split = WalletConnectSwapReview(try request("split-routes"))
        XCTAssertEqual(split.routes.count, 2)
        XCTAssertNotEqual(split.routes[0].output.reference, split.routes[1].output.reference)
        let balance = WalletConnectSwapReview(try request("contract-balance-swap"))
        XCTAssertEqual(balance.routes[0].input.bound, .routerBalance)
    }
    func testUnrecognizedRouterOrWrongChainCannotInventPair() throws {
        for input in [try request("v3-exact-in", chain: 56), try request("v3-exact-in", to: a)] {
            let review = WalletConnectSwapReview(input)
            XCTAssertTrue(review.routes.isEmpty)
            XCTAssertTrue(review.incomplete)
        }
    }
    func testSameAddressOnAnotherNetworkKeepsNetworkIdentity() throws {
        for chain: UInt64 in [56, 8453] {
            let review = WalletConnectSwapReview(try request("v3-exact-in", chain: chain, to: "0xd9c500dff816a1da21a48a732d3498bf09dc9aeb"))
            XCTAssertEqual(review.chainID, chain)
            XCTAssertEqual(review.routes[0].input.reference, a)
        }
    }
    func testV2AllMethodsIncludeNativeDirectionAndBounds() throws {
        for method in ["swapExactTokensForTokens", "swapTokensForExactTokens", "swapExactETHForTokens", "swapETHForExactTokens", "swapExactTokensForETH", "swapTokensForExactETH", "swapExactTokensForTokensSupportingFeeOnTransferTokens", "swapExactETHForTokensSupportingFeeOnTransferTokens", "swapExactTokensForETHSupportingFeeOnTransferTokens"] {
            let nativeIn = method.contains("ETHFor"), nativeOut = method.contains("ForETH") || method.contains("ForExactETH")
            let exactOut = !method.hasPrefix("swapExact")
            let req = try request("direct-" + method, to: "0x7a250d5630b4cf539739df2c5dacb4c659f2488d", value: nativeIn ? "0x75bcd15" : "0x0")
            let review = WalletConnectSwapReview(req), route = try XCTUnwrap(review.routes.first, method)
            XCTAssertFalse(review.incomplete, method)
            XCTAssertEqual(route.input.reference, nativeIn ? "native" : a, method)
            XCTAssertEqual(route.output.reference, nativeOut ? "native" : c, method)
            XCTAssertEqual(route.input.bound, exactOut ? .maximum : .exact, method)
            XCTAssertEqual(route.output.bound, exactOut ? .exact : .minimum, method)
            XCTAssertEqual(route.input.amount, exactOut && !nativeIn ? "100000000" : "123456789", method)
            XCTAssertEqual(route.output.amount, exactOut && !nativeIn ? "123456789" : "100000000", method)
            XCTAssertEqual(WalletConnectCallDetails(req).deadline, "2000000000")
        }
    }
    func testV2DeploymentsAndMalformedDataFailClosed() throws {
        let routers: [(UInt64, String)] = [(1,"0xeff92a263d31888d860bd50809a8d171709b7b1c"), (56,"0x10ed43c718714eb63d5aa57b78b54704e256024e"), (8453,"0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"), (42161,"0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"), (59144,"0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb"), (143,"0xb1bc24c34e88f7d43d5923034e3a14b24daacff9"), (4663,"0x8cfe327cec66d1c090dd72bd0ff11d690c33a2eb")]
        for (chain, to) in routers {
            let req = try request("direct-swapExactTokensForTokens", chain: chain, to: to)
            XCTAssertEqual(WalletConnectSwapReview(req).routes.count, 1)
            XCTAssertEqual(WalletConnectSwapReview(req).chainID, chain)
            for data in [req.call.hex + "00", String(req.call.hex.dropLast(2)), String(req.call.hex.prefix(10)) + String(repeating: "ff", count: 160)] {
                let bad = try WalletConnectEVMRequest(params: JSONSerialization.data(withJSONObject: [["from":owner,"to":to,"data":data]]), account: owner, chainID: chain)
                XCTAssertTrue(WalletConnectSwapReview(bad).routes.isEmpty)
            }
            let before = req.call.bytes
            _ = WalletConnectSwapReview(req)
            XCTAssertEqual(before, req.call.bytes)
        }
    }
    func testApprovalIsNeverLabeledSwap() throws {
        let data = "0x095ea7b3" + String(repeating: "0", count: 24) + String(a.dropFirst(2)) + String(repeating: "f", count: 64)
        for chain in EVMSendNetwork.allCases {
            let req = try WalletConnectEVMRequest(params: JSONSerialization.data(withJSONObject: [["from":owner,"to":c,"data":data]]), account: owner, chainID: chain.chainID)
            XCTAssertEqual(WalletConnectEVMAction(req).kind, .approval)
            XCTAssertTrue(WalletConnectSwapReview(req).routes.isEmpty)
            XCTAssertFalse(WalletConnectSwapReview(req).incomplete)
        }
    }

    func testConfirmedSepoliaTransactionsShowTheirActualNativeDirection() throws {
        struct Confirmed: Decodable {
            let name: String, from: String, to: String, value: String, data: String
            let chainID: UInt64, receiptStatus: Int
        }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "confirmed-swaps", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        let fixtures = try JSONDecoder().decode([Confirmed].self, from: Data(contentsOf: file))
        XCTAssertEqual(fixtures.count, 4)
        for fixture in fixtures {
            XCTAssertEqual(fixture.receiptStatus, 1)
            let request = try WalletConnectEVMRequest(params: JSONSerialization.data(withJSONObject: [["from": fixture.from, "to": fixture.to, "value": fixture.value, "data": fixture.data]]), account: fixture.from, chainID: fixture.chainID)
            let review = WalletConnectSwapReview(request)
            XCTAssertFalse(review.incomplete, fixture.name)
            XCTAssertEqual(review.routes.count, 1, fixture.name)
            let route = try XCTUnwrap(review.routes.first)
            XCTAssertEqual(route.recipient, fixture.from, fixture.name)
            XCTAssertEqual(route.input.reference == "native", fixture.name.contains("native-to-token"), fixture.name)
            XCTAssertEqual(route.output.reference == "native", fixture.name.contains("token-to-native"), fixture.name)
            XCTAssertEqual(request.call.hex, fixture.data)
        }
    }

    func testSinglePoolRouterBalanceAndNativeFunding() throws {
        func make(amount: String, value: String) throws -> WalletConnectEVMRequest {
            func word(_ s: String) -> String { String(repeating: "0", count: 64 - s.count) + s }
            let data = "0x04e45aaf" + [String(WalletConnectSwapReview.wrappedNative[1]!.dropFirst(2)), String(c.dropFirst(2)), "bb8", String(owner.dropFirst(2)), amount, "1", "0"].map(word).joined()
            return try .init(params: JSONSerialization.data(withJSONObject: [["from": owner,"to":"0x68b3465833fb72a70ecdf485e0e4c7bd8665fc45","data":data,"value":value]]), account: owner, chainID: 1)
        }
        let balance = WalletConnectSwapReview(try make(amount: "0", value: "0x0"))
        XCTAssertEqual(balance.routes[0].input.bound, .routerBalance)
        let native = WalletConnectSwapReview(try make(amount: "64", value: "0x64"))
        XCTAssertEqual(native.routes[0].input.reference, "native")
        let wrapped = WalletConnectSwapReview(try make(amount: "64", value: "0x0"))
        XCTAssertEqual(wrapped.routes[0].input.reference, WalletConnectSwapReview.wrappedNative[1])
    }
}
