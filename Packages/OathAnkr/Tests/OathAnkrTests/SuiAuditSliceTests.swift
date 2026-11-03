import XCTest
@testable import OathAnkr

final class SuiAuditSliceTests: XCTestCase {
    func bytes() throws -> Data {
        let funds = SuiSendFunds(coins: [], addressBalance: 1_000_000_000)
        return try SuiSendPlan.make(network: .mainnet, sender: "0x1", recipient: "0xabc", reference: "native",
            amount: 1_000_000, native: funds, asset: funds, gasPrice: 1000, gasBudget: 5_000_000,
            epoch: 1252, nonce: 42).transactionBytes()
    }
    func testZeroOriginTransactionControl() throws {
        let bytes = try bytes()
        let parsed = try WalletConnectSuiTransaction(bytes, network: .mainnet, account: "0x1", executing: true)
        XCTAssertEqual(parsed.sender, try SuiIdentity.address("0x1"))
        XCTAssertEqual(parsed.gasBudget, 5_000_000)
        XCTAssertEqual(parsed.minimumEpoch, 1252)
        XCTAssertFalse(parsed.commands.isEmpty)
    }
    func testNonzeroOriginTransactionMatchesControl() throws {
        let bytes = try bytes()
        let control = try WalletConnectSuiTransaction(bytes, network: .mainnet, account: "0x1", executing: true)
        for prefix in [1,2,17,128] {
            let slice = (Data(repeating: 0xaa, count: prefix) + bytes).dropFirst(prefix)
            XCTAssertEqual(slice.startIndex, prefix)
            let parsed = try WalletConnectSuiTransaction(slice, network: .mainnet, account: "0x1", executing: true)
            XCTAssertEqual(parsed.sender, control.sender)
            XCTAssertEqual(parsed.gasBudget, control.gasBudget)
            XCTAssertEqual(parsed.commands, control.commands)
            XCTAssertEqual(parsed.inputs, control.inputs)
        }
    }
    func testNonzeroOriginTruncatedTransactionsThrow() throws {
        let bytes = try bytes()
        for length in 0..<bytes.count {
            let slice = (Data([0xaa,0xbb]) + bytes.prefix(length)).dropFirst(2)
            XCTAssertThrowsError(try WalletConnectSuiTransaction(slice, network: .mainnet, account: "0x1", executing: true), "length \(length)")
        }
    }
}
