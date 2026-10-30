import XCTest
@testable import OathAnkr

final class WalletConnectEVMActionTests: XCTestCase {
    struct Vector: Decodable { let name: String, kind: String, request: String, signed: String, hash: String }
    private func vectors() throws -> [Vector] {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "evm-data", withExtension: "json", subdirectory: "Fixtures/WalletConnect"))
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: file))
    }
    func testIndependentABIAndExactTransactionSignatures() throws {
        let owner = try EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32))
        for vector in try vectors() {
            let input = try WalletConnectEVMRequest(params: Data(vector.request.utf8), account: owner, chainID: 1)
            let action = WalletConnectEVMAction(input)
            XCTAssertEqual(String(describing: action.kind), vector.kind, vector.name)
            let plan = EVMSendPlan(network: .ethereum, sender: input.sender, recipient: input.recipient, reference: "native", decimals: 18,
                requestedAmount: input.value, amount: input.value, assetBalance: "1000000000000000000", nativeBalance: "1000000000000000000",
                nonce: 7, gasLimit: 60000, maxFeePerGas: 1_000_000_000, maxPriorityFeePerGas: 1, blockHeight: 100, call: input.call)
            XCTAssertTrue(input.matches(plan))
            let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
            XCTAssertEqual("0x" + TronSendCrypto.hex(signed.bytes), vector.signed, vector.name)
            XCTAssertEqual(signed.hash, vector.hash, vector.name)
            if vector.name == "approval" { XCTAssertTrue(action.isUnlimited); XCTAssertEqual(action.fields.last?.value, WalletConnectEVMAction.maximum) }
            if vector.name == "swap" { XCTAssertEqual(action.fields.first { $0.label == .minimumReceived }?.value, "990000") }
        }
    }
    func testMalformedAndSpoofedCalldataNeverGetsFriendlyInterpretation() throws {
        let owner = try EVMSendCrypto.address(privateKey: Data(repeating: 1, count: 32))
        let vector = try XCTUnwrap(vectors().first { $0.name == "approval" })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(vector.request.utf8)) as? [[String: String]])
        let data = try XCTUnwrap(json[0]["data"])
        for malformed in [data + "00", String(data.dropLast(2)), "0x095ea7b3" + String(repeating: "f", count: 128)] {
            var altered = json; altered[0]["data"] = malformed
            let request = try WalletConnectEVMRequest(params: JSONSerialization.data(withJSONObject: altered), account: owner, chainID: 1)
            XCTAssertEqual(WalletConnectEVMAction(request).kind, .contract)
        }
        var payable = json; payable[0]["value"] = "0x1"
        let request = try WalletConnectEVMRequest(params: JSONSerialization.data(withJSONObject: payable), account: owner, chainID: 1)
        XCTAssertEqual(WalletConnectEVMAction(request).kind, .contract)
    }
}
