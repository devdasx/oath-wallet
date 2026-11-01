import XCTest
@testable import OathAnkr

/// The production approval model must distinguish requests that move different
/// funds, even when their exchange route is identical. No network or keys.
final class WalletConnectApprovalOperationsTests: XCTestCase {
    private struct Vector: Decodable { let name: String; let data: String }
    private func request(_ name: String, chain: UInt64 = 1) throws -> WalletConnectEVMRequest {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "approval-operations", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        let rows = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        let data = try XCTUnwrap(rows.first { $0.name == name }).data
        let owner = "0x4444444444444444444444444444444444444444"
        return try .init(params: JSONSerialization.data(withJSONObject: [[
            "from": owner, "to": "0x65b382653f7c31bc0af67f188122035461ec9c76", "value": "0x0", "data": data
        ]]), account: owner, chainID: chain)
    }

    func testAdditionalOperationsCannotDisappearFromApprovalModel() throws {
        let base = WalletConnectSwapReview(try request("swap-only"))
        XCTAssertEqual(base.routes.count, 1)
        for name in ["swap-transfer-2", "swap-transfer-4", "swap-transfer-5", "transfer-before-swap", "nested-optional-transfer", "swap-balance-check"] {
            let input = try request(name), details = WalletConnectCallDetails(input)
            XCTAssertTrue(details.fullyDecoded, name)
            XCTAssertEqual(details.steps.count, 2, name)
            let mixed = WalletConnectSwapReview(input)
            XCTAssertEqual(mixed.routes, base.routes, "Control: the exchange itself is unchanged")
            XCTAssertNotEqual(mixed, base, "Approval must retain additional operations: \(name)")
        }
    }

    func testExtraRecipientAmountAndExecutionOrderAffectApproval() throws {
        let base = WalletConnectSwapReview(try request("swap-transfer-2"))
        for name in ["swap-other-recipient", "swap-other-amount", "transfer-before-swap", "nested-optional-transfer"] {
            XCTAssertNotEqual(WalletConnectSwapReview(try request(name)), base,
                              "Approval must retain transfer semantics: \(name)")
        }
    }

    func testDecoderAndStrictBoundaryControls() throws {
        let details = WalletConnectCallDetails(try request("swap-transfer-2"))
        XCTAssertEqual(details.steps.map(\.command), ["0x00", "0x02"])
        XCTAssertEqual(details.steps.last?.operation, .transfer)
        XCTAssertEqual(details.steps.last?.values.first(where: { $0.label == .recipient })?.value, "0x6666666666666666666666666666666666666666")
        XCTAssertEqual(details.steps.last?.values.first(where: { $0.label == .amount })?.value, "987654321")
        XCTAssertEqual(details.steps.last?.values.first(where: { $0.label == .tokenIn })?.value, "0x5555555555555555555555555555555555555555")
        let nested = WalletConnectCallDetails(try request("nested-optional-transfer"))
        XCTAssertEqual(nested.steps.last?.optional, true)
        XCTAssertTrue(WalletConnectSwapReview(try request("swap-unknown")).incomplete)
        let wrongChain = WalletConnectSwapReview(try request("swap-transfer-2", chain: 56))
        XCTAssertTrue(wrongChain.incomplete)
        XCTAssertTrue(wrongChain.routes.isEmpty)
    }
}
