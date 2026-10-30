import XCTest
@testable import OathAnkr

final class PermissionCheckInputTests: XCTestCase {
    private let contract = "0x" + String(repeating: "a", count: 40)
    private let spender = "0x" + String(repeating: "b", count: 40)

    func testMalformedFormAddressesAreValidationErrors() throws {
        for invalid in ["", "hello", "0x123", "0x" + String(repeating: "g", count: 40), EVMPermissionRemoval.zero] {
            for pair in [(invalid, spender), (contract, invalid)] {
                XCTAssertThrowsError(try PermissionCheckInput.evm(kind: .token, contract: pair.0,
                    spender: pair.1, tokenID: nil)) { error in
                    XCTAssertEqual(error as? PermissionError, .malformed)
                }
            }
        }
    }

    func testNormalizedInputAndKindSpecificFields() throws {
        let token = try PermissionCheckInput.evm(kind: .token, contract: " \n" + contract,
            spender: spender + "\n", tokenID: "stale field")
        XCTAssertEqual(token.contract, contract)
        XCTAssertEqual(token.spender, spender)
        XCTAssertNil(token.tokenID)
        for kind in [EVMPermissionRemoval.Kind.permit2, .permit2Nonce] {
            let value = try PermissionCheckInput.evm(kind: kind, contract: EVMPermissionRemoval.permit2,
                spender: spender, tokenID: " " + contract + " ")
            XCTAssertEqual(value.tokenID, contract)
            for invalid in ["", "12", EVMPermissionRemoval.zero] {
                XCTAssertThrowsError(try PermissionCheckInput.evm(kind: kind, contract: EVMPermissionRemoval.permit2,
                    spender: spender, tokenID: invalid)) { XCTAssertEqual($0 as? PermissionError, .malformed) }
            }
            XCTAssertThrowsError(try PermissionCheckInput.evm(kind: kind, contract: contract,
                spender: spender, tokenID: contract))
        }
    }

    func testCollectibleIDMustFitUnsigned256Bits() throws {
        let maximum = "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        for id in ["0", "42", maximum] {
            XCTAssertEqual(try PermissionCheckInput.evm(kind: .collectible, contract: contract,
                spender: spender, tokenID: id).tokenID, id)
        }
        for id in [nil, "", "-1", "1.2", "abc", maximum + "0"] {
            XCTAssertThrowsError(try PermissionCheckInput.evm(kind: .collectible, contract: contract,
                spender: spender, tokenID: id)) { XCTAssertEqual($0 as? PermissionError, .malformed) }
        }
    }
}
