import XCTest
@testable import OathAnkr

final class WalletConnectCallDetailsTests: XCTestCase {
    struct Vector: Decodable { let name: String, data: String }
    let sender = "0x4444444444444444444444444444444444444444"
    let router = "0x65b382653f7c31bc0af67f188122035461ec9c76"
    let tokenA = "0x1111111111111111111111111111111111111111"
    let tokenC = "0x3333333333333333333333333333333333333333"
    func bytes(_ name: String) throws -> String {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "call-details", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        return try XCTUnwrap(JSONDecoder().decode([Vector].self, from: Data(contentsOf: file)).first { $0.name == name }).data
    }
    func request(_ data: String, chain: UInt64 = 1, to: String? = nil) throws -> WalletConnectEVMRequest {
        try .init(params: JSONSerialization.data(withJSONObject: [["from": sender, "to": to ?? router, "data": data, "value": "0x0"]]), account: sender, chainID: chain)
    }
    func details(_ name: String) throws -> WalletConnectCallDetails { try .init(request(bytes(name))) }

    func testIndependentSwapVectorsRetainUnitsTokensAndPayer() throws {
        for name in ["v3-exact-in", "v3-exact-out", "v2-exact-in", "v2-exact-out"] {
            let detail = try details(name), step = try XCTUnwrap(detail.steps.first)
            XCTAssertTrue(detail.fullyDecoded, name)
            XCTAssertEqual(detail.deadline, "2000000000")
            XCTAssertEqual(step.operation, .swap)
            XCTAssertEqual(step.values.first { $0.label == .tokenIn }?.value, tokenA)
            XCTAssertEqual(step.values.first { $0.label == .tokenOut }?.value, tokenC)
            let input = try XCTUnwrap(step.values.first { $0.token == tokenA })
            let output = try XCTUnwrap(step.values.first { $0.token == tokenC })
            XCTAssertEqual(input.value, "123456789")
            XCTAssertEqual(output.value, "100000000")
            XCTAssertEqual(input.label, name.contains("out") ? .maximumSpent : .amount)
            XCTAssertEqual(output.label, name.contains("out") ? .amount : .minimumReceived)
            XCTAssertEqual(step.values.first { $0.label == .recipient }?.value, sender)
            XCTAssertEqual(step.values.first { $0.label == .owner }?.value, name == "v2-exact-out" ? router : sender)
        }
    }
    func testNestedScreenshotShapeIncludesEveryStep() throws {
        let detail = try details("nested-swap-sweep")
        XCTAssertEqual(detail.method, "execute(bytes,bytes[],uint256)")
        XCTAssertEqual(detail.steps.map(\.operation), [.balanceCheck, .swap, .unwrap, .transfer])
        XCTAssertTrue(detail.fullyDecoded)
        XCTAssertTrue(detail.steps.allSatisfy { !$0.optional })
    }
    func testOptionalSubplanPreservesFailureSemantics() throws {
        let detail = try details("optional-nested")
        XCTAssertEqual(detail.steps.count, 2)
        XCTAssertTrue(detail.steps.allSatisfy(\.optional))
    }
    func testUnknownCommandsAndDepthAreNeverOmitted() throws {
        let partial = try details("unknown-and-sweep")
        XCTAssertEqual(partial.steps.map(\.operation), [.unknown, .transfer])
        XCTAssertFalse(partial.fullyDecoded)
        for name in ["reserved-bit", "noncanonical-bool", "invalid-path", "unknown-extra-argument", "too-deep"] {
            let detail = try details(name)
            XCTAssertTrue(detail.isRouter, name)
            XCTAssertFalse(detail.fullyDecoded, name)
            XCTAssertEqual(detail.steps.last?.operation, .unknown, name)
        }
    }
    func testSentinelsAreNotDisplayedAsHugeTokenAmounts() throws {
        let detail = try details("wrap-transfer")
        XCTAssertNil(detail.deadline)
        XCTAssertEqual(detail.steps.map(\.operation), [.wrap, .transfer])
        XCTAssertTrue(detail.steps.allSatisfy { $0.values.last?.routerBalance == true })
        let nativeTransfer = try details("native-transfer-literal")
        XCTAssertTrue(nativeTransfer.fullyDecoded)
        XCTAssertFalse(try XCTUnwrap(nativeTransfer.steps.first?.values.last).routerBalance)
        XCTAssertEqual(detail.steps.first?.values.first?.value, router)
        XCTAssertTrue(try details("contract-balance-swap").steps[0].values[1].routerBalance)
        let permit = try details("permit-transfer")
        XCTAssertEqual(permit.steps[0].values.first(where: { $0.label == .recipient })?.value, router)
        XCTAssertEqual(permit.steps[0].values.first(where: { $0.label == .owner })?.value, sender)
        XCTAssertFalse(try XCTUnwrap(permit.steps[0].values.first(where: { $0.label == .amount })).routerBalance)
    }
    func testRouterTrustRequiresChainAndAddress() throws {
        let data = try bytes("v3-exact-in")
        XCTAssertFalse(try WalletConnectCallDetails(request(data, chain: 56)).isRouter)
        XCTAssertFalse(try WalletConnectCallDetails(request(data, to: tokenA)).isRouter)
        for (chain, address) in [(UInt64(1),"0x66a9893cc07d91d95644aedd05d03f95e1dba8af"), (11155111,"0x3a9d48ab9751398bbfa63ad67599bb04e4bdf98b"), (56,"0xd9c500dff816a1da21a48a732d3498bf09dc9aeb"), (8453,"0x6ff5693b99212da76ad316178a184ab56d299b43")] {
            XCTAssertTrue(try WalletConnectCallDetails(request(data, chain: chain, to: address)).fullyDecoded)
        }
    }
    func testStandardTokenActionsAreIndependentOfDAppAndNetwork() throws {
        let data = "0xa9059cbb" + String(repeating: "0", count: 24) + String(sender.dropFirst(2))
            + String(repeating: "0", count: 60) + "03e8"
        for chain in EVMSendNetwork.allCases {
            let req = try request(data, chain: chain.chainID, to: tokenA)
            let action = WalletConnectEVMAction(req)
            XCTAssertEqual(action.kind, .transfer, chain.rawValue)
            XCTAssertEqual(action.fields.last?.value, "1000", chain.rawValue)
            XCTAssertEqual(WalletConnectCallDetails(req).method, "transfer(address,uint256)", chain.rawValue)
        }
    }
    func testHistoryAcceptsCanonicalPerHopLimitsForV2V3ExactInAndOut() throws {
        struct HistoryVector: Decodable { let name: String, data: String, valid: Bool }
        let file = try XCTUnwrap(Bundle.module.url(forResource: "history-hop-prices", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        let vectors = try JSONDecoder().decode([HistoryVector].self, from: Data(contentsOf: file))
        for vector in vectors {
            let req = try request(vector.data)
            let details = WalletConnectCallDetails(history: req)
            XCTAssertEqual(details.fullyDecoded, vector.valid, vector.name)
            XCTAssertFalse(WalletConnectCallDetails(req).fullyDecoded, vector.name)
            if vector.valid {
                let step = try XCTUnwrap(details.steps.first)
                XCTAssertEqual(step.operation, .swap)
                XCTAssertEqual(step.values.first { $0.label == .tokenIn }?.value, tokenA)
                XCTAssertEqual(step.values.first { $0.label == .tokenOut }?.value, tokenC)
                XCTAssertEqual(step.values.first { $0.label == .recipient }?.value, sender)
            }
        }
    }

    func testTruncationBadOffsetsAndTrailingDataFailClosed() throws {
        let original = try bytes("nested-swap-sweep")
        for n in stride(from: 10, to: original.count, by: 32) {
            XCTAssertFalse(try WalletConnectCallDetails(request(String(original.prefix(n)))).isRouter)
        }
        XCTAssertFalse(try WalletConnectCallDetails(request(original + "00")).isRouter)
        var data = try TronIdentity.hex(String(original.dropFirst(2)))
        for index in [4, 35, 36, 67, 131] {
            var changed = data; changed[index] = 255
            XCTAssertFalse(try WalletConnectCallDetails(request("0x" + TronSendCrypto.hex(changed))).isRouter)
        }
        // Mutating the display model cannot modify the immutable signing input.
        let req = try request(original), before = req.call.bytes
        _ = WalletConnectCallDetails(req)
        XCTAssertEqual(req.call.bytes, before)
        data.removeAll()
    }
}
