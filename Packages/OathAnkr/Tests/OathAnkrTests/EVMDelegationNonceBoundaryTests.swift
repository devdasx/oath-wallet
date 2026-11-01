import Foundation
import XCTest
@testable import OathAnkr

final class EVMDelegationNonceBoundaryTests: XCTestCase {
    private func plan(nonce: UInt64, delegation: Bool = true, legacy: Bool = false) -> EVMSendPlan {
        let owner = "0x" + String(repeating: "1", count: 40)
        let delegate = "0x" + String(repeating: "2", count: 40)
        return .init(network: .ethereumSepolia, sender: owner, recipient: owner,
                     reference: "native", decimals: 18, requestedAmount: "0", amount: "0",
                     assetBalance: "0", nativeBalance: "0", nonce: nonce,
                     gasLimit: 70_000, maxFeePerGas: 1_000_000_000,
                     maxPriorityFeePerGas: 0, blockHeight: 1, legacy: legacy,
                     removal: delegation ? .init(kind: .delegation, contract: owner,
                                                spender: delegate, expected: delegate) : nil)
    }

    func testMaximumNonceThrowsInsteadOfOverflowing() {
        XCTAssertThrowsError(try EVMSendCrypto.unsignedBytes(plan(nonce: .max))) {
            XCTAssertEqual($0 as? EVMSendError, .signing)
        }
    }

    func testReservedAuthorizationNonceIsRejected() {
        XCTAssertThrowsError(try EVMSendCrypto.unsignedBytes(plan(nonce: UInt64.max - 1))) {
            XCTAssertEqual($0 as? EVMSendError, .signing)
        }
    }

    func testValidDelegationSizingDoesNotRequireFundedPlan() throws {
        // Fee sizing precedes final funding validation. Preserve that contract.
        for nonce: UInt64 in [0, 7, UInt64.max - 2] {
            XCTAssertEqual(try EVMSendCrypto.unsignedBytes(plan(nonce: nonce)).first, 4)
        }
    }

    func testOrdinaryTransactionsDoNotAddAuthorizationNonce() throws {
        for legacy in [false, true] {
            let bytes = try EVMSendCrypto.unsignedBytes(plan(nonce: .max, delegation: false, legacy: legacy))
            XCTAssertFalse(bytes.isEmpty)
            if !legacy { XCTAssertEqual(bytes.first, 2) }
        }
    }
}
