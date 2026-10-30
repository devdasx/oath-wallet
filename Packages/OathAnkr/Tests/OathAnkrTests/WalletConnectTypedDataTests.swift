import XCTest
@testable import OathAnkr

final class WalletConnectTypedDataTests: XCTestCase {
    struct Vector: Decodable {
        let name: String, json: String, digest: String, signature: String, account: String
        let chainId: UInt64
        func decode(_ value: String? = nil, chain: UInt64? = nil, account: String? = nil) throws -> WalletConnectTypedData {
            try .init(json: Data((value ?? json).utf8), chainID: chain ?? chainId, account: account ?? self.account)
        }
    }
    func vectors() throws -> [Vector] {
        let url = Bundle.module.url(forResource: "typed-data", withExtension: "json", subdirectory: "Fixtures/WalletConnect")!
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }
    func testReadablePermissionPreservesSignedAmountsAndSeparateExpiries() throws {
        for vector in try vectors() where ["permit", "permit2-allowance", "permit2-transfer"].contains(vector.name) {
            let typed = try vector.decode()
            let permission = try XCTUnwrap(typed.permission)
            XCTAssertFalse(permission.tokenAddress.isEmpty)
            XCTAssertFalse(permission.spenderAddress.isEmpty)
            XCTAssertEqual(permission.signatureDeadline, "2000000000")
            XCTAssertEqual(permission.allowanceExpiration, vector.name == "permit2-allowance" ? "2000000100" : nil)
            XCTAssertEqual(permission.isOneTimeTransfer, vector.name == "permit2-transfer")
            XCTAssertEqual("0x" + TronSendCrypto.hex(typed.digest), vector.digest)
        }
    }
    func testUnlimitedAllowanceUsesProtocolWidthAndNeverRelabelsSingleUseTransfer() {
        let token = "0x1111111111111111111111111111111111111111"
        let spender = "0x2222222222222222222222222222222222222222"
        let maximum160 = "1461501637330902918203684832716283019655932542975"
        let allowance = WalletConnectTypedData.Permission.permit2Allowance(token: token, spender: spender,
            amount: maximum160, nonce: "1", expiration: "0", deadline: "2000000000")
        XCTAssertTrue(allowance.isUnlimitedAllowance)
        XCTAssertEqual(allowance.allowanceExpiration, "0")
        XCTAssertEqual(allowance.atomicAmount, maximum160)
        let finite = WalletConnectTypedData.Permission.erc2612(token: token, owner: token, spender: spender,
            amount: maximum160, nonce: "1", deadline: "2000000000")
        XCTAssertFalse(finite.isUnlimitedAllowance)
        let unlimited = WalletConnectTypedData.Permission.erc2612(token: token, owner: token, spender: spender,
            amount: WalletConnectEVMAction.maximum, nonce: "1", deadline: "2000000000")
        XCTAssertTrue(unlimited.isUnlimitedAllowance)
        let transfer = WalletConnectTypedData.Permission.permit2Transfer(token: token, spender: spender,
            amount: WalletConnectEVMAction.maximum, nonce: "1", deadline: "2000000000")
        XCTAssertFalse(transfer.isUnlimitedAllowance)
        XCTAssertTrue(transfer.isOneTimeTransfer)
        XCTAssertEqual(transfer.spenderAddress, spender)
    }
    func testIndependentEthersHashesAndSignatures() throws {
        for v in try vectors() {
            let typed = try v.decode()
            XCTAssertEqual("0x" + TronSendCrypto.hex(typed.digest), v.digest, v.name)
            XCTAssertEqual(try typed.sign(privateKey: Data(repeating: 1, count: 32), account: v.account), v.signature, v.name)
            XCTAssertThrowsError(try typed.sign(privateKey: Data(repeating: 2, count: 32), account: v.account), v.name)
        }
        let mail = try vectors().first { $0.name == "official-mail" }!
        XCTAssertEqual(mail.digest, "0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2")
    }
    func testRejectsChainMismatchMissingFieldsExtraFieldsAndInvalidWidths() throws {
        let v = try vectors().first { $0.name == "uint8" }!
        XCTAssertThrowsError(try v.decode(chain: 2))
        for changed in [
            v.json.replacingOccurrences(of: "\"255\"", with: "\"256\""),
            v.json.replacingOccurrences(of: "\"255\"", with: "-1"),
            v.json.replacingOccurrences(of: "\"255\"", with: "true"),
            v.json.replacingOccurrences(of: "\"255\"", with: "1.2"),
            v.json.replacingOccurrences(of: "\"255\"", with: "1e2"),
            v.json.replacingOccurrences(of: "\"255\"", with: "\"0255\""),
            v.json.replacingOccurrences(of: "\"value\":\"255\"", with: "\"extra\":\"255\""),
            v.json.replacingOccurrences(of: "\"value\":\"255\"", with: "\"value\":\"255\",\"extra\":0"),
            v.json.replacingOccurrences(of: "uint8", with: "uint7"),
            v.json.replacingOccurrences(of: "uint8", with: "uint"),
            v.json.replacingOccurrences(of: "uint8", with: "uint264"),
            v.json.replacingOccurrences(of: "uint8", with: "uint08"),
            v.json.replacingOccurrences(of: "uint8", with: "MissingStruct")
        ] { XCTAssertThrowsError(try v.decode(changed)) }
        let negative = try vectors().first { $0.name == "int8-min" }!
        XCTAssertThrowsError(try negative.decode(negative.json.replacingOccurrences(of: "-128", with: "-129")))
        XCTAssertThrowsError(try negative.decode(negative.json.replacingOccurrences(of: "-128", with: "128")))
    }
    func testDuplicateKeysAndLargeJSONIntegersNeverRound() throws {
        let v = try vectors().first { $0.name == "uint256-json-literal" }!
        let decoded = try v.decode()
        XCTAssertEqual(decoded.fields.last?.value, "115792089237316195423570985008687907853269984665640564039457584007913129639935")
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{\"value\":1,\"value\":2}".utf8)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{\"value\":1,\"\\u0076alue\":2}".utf8)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{\"value\":01}".utf8)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("{}{}".utf8)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data(String(repeating: "[", count: 34).utf8)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data(repeating: 32, count: 65_537)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("[true,]".utf8)))
        XCTAssertThrowsError(try WalletConnectJSON.decode(Data("\"\\ud800\"".utf8)))
    }
    func testPermitMeaningAndOwnershipCannotBeConfused() throws {
        let vs = try vectors()
        let permit = vs.first { $0.name == "permit" }!
        guard case .erc2612(_, _, _, let amount, _, let deadline) = try permit.decode().permission else { return XCTFail("Expected EIP-2612") }
        XCTAssertEqual(amount, "100000000"); XCTAssertEqual(deadline, "2000000000")
        XCTAssertThrowsError(try permit.decode(account: "0x" + String(repeating: "2", count: 40)))
        let allowance = vs.first { $0.name == "permit2-allowance" }!
        guard case .permit2Allowance(_, _, _, _, let expiry, let signatureDeadline) = try allowance.decode().permission else { return XCTFail("Expected Permit2 allowance") }
        XCTAssertEqual(expiry, "2000000100"); XCTAssertEqual(signatureDeadline, "2000000000")
        XCTAssertNil(try allowance.decode(allowance.json.replacingOccurrences(of: "0x000000000022D473030F116dDEE9F6B43aC78BA3", with: "0x1111111111111111111111111111111111111111")).permission)
        guard case .permit2Transfer = try vs.first(where: { $0.name == "permit2-transfer" })!.decode().permission else { return XCTFail("Expected one-use transfer") }
    }
    func testReviewIncludesNestedValuesAndShowsInvisibleCharacters() throws {
        let vs = try vectors()
        let nested = try vs.first { $0.name == "arrays" }!.decode()
        XCTAssertTrue(nested.fields.contains { $0.path == "message.items[1].label" && $0.value == "Second" })
        XCTAssertTrue(nested.fields.contains { $0.path == "message.grid[0][0]" && $0.value == "-32768" })
        XCTAssertTrue(nested.fields.contains { $0.path == "message.empty" && $0.value == "0" })
        let atomic = try vs.first { $0.name == "atomic" }!.decode()
        XCTAssertTrue(atomic.fields.contains { $0.value.contains("\\u{202E}") })
        XCTAssertEqual(WalletConnectTypedData.visible("hello\u{200b}\nworld"), "hello\\u{200B}\\u{000A}world")
    }

    func testPermissionDeadlinesStayExactAndAreRecheckedAtSigning() throws {
        let vs = try vectors()
        for name in ["permit", "permit2-allowance", "permit2-transfer"] {
            let v = try XCTUnwrap(vs.first { $0.name == name })
            let request = try v.decode()
            XCTAssertNoThrow(try request.validatePermissionTime(now: Date(timeIntervalSince1970: 2_000_000_000)))
            XCTAssertThrowsError(try request.validatePermissionTime(now: Date(timeIntervalSince1970: 2_000_000_001))) {
                XCTAssertEqual($0 as? WalletConnectTypedData.Failure, .expired)
            }
        }
        let allowance = try XCTUnwrap(vs.first { $0.name == "permit2-allowance" })
        let expired = try allowance.decode(allowance.json.replacingOccurrences(of: "2000000100", with: "1999999999"))
        XCTAssertThrowsError(try expired.validatePermissionTime(now: Date(timeIntervalSince1970: 2_000_000_000)))
        let currentBlock = try allowance.decode(allowance.json.replacingOccurrences(of: "2000000100", with: "0"))
        XCTAssertNoThrow(try currentBlock.validatePermissionTime(now: Date(timeIntervalSince1970: 2_000_000_000)))
        let permit = try XCTUnwrap(vs.first { $0.name == "permit" })
        let unlimitedTime = try permit.decode(permit.json.replacingOccurrences(of: "2000000000", with: String(repeating: "9", count: 76)))
        XCTAssertNoThrow(try unlimitedTime.validatePermissionTime(now: Date(timeIntervalSince1970: 2_000_000_001)))
    }
}
