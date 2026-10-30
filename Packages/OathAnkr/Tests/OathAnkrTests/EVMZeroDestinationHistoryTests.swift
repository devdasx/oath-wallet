import XCTest
@testable import OathAnkr

final class EVMZeroDestinationHistoryTests: XCTestCase {
    func testConfirmedZeroDestinationIsNotASwapOrContractCall() throws {
        let helper = EVMHistorySwapTests(), original = try helper.fixture()
        for network in EVMSendNetwork.allCases {
            for input in ["0x", "0x12345678"] {
                var tx = helper.replacing(original.transaction, "chainId", .string("0x" + String(network.chainID, radix: 16)))
                tx = helper.replacing(tx, "to", .string(EVMPermissionRemoval.zero))
                tx = helper.replacing(tx, "value", .string("0x0"))
                tx = helper.replacing(tx, "input", .string(input))
                let receipt = helper.replacing(helper.replacing(original.receipt, "to", .string(EVMPermissionRemoval.zero)), "logs", .array([]))
                XCTAssertNil(try EVMHistorySwap.classify(transaction: tx, receipt: receipt, owner: helper.owner, chainID: network.chainID))
                XCTAssertNil(try EVMHistoryContractCall.classify(transaction: tx, receipt: receipt, owner: helper.owner, chainID: network.chainID))
                let request = try JSONEncoder().encode([["from": helper.owner, "to": EVMPermissionRemoval.zero, "data": input, "value": "0x0"]])
                XCTAssertThrowsError(try WalletConnectEVMRequest(params: request, account: helper.owner, chainID: network.chainID), "History classification must not loosen signing validation")
            }
        }
    }

}
