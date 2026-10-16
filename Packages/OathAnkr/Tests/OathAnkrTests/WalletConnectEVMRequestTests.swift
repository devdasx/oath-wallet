import XCTest
@testable import OathAnkr

final class WalletConnectEVMRequestTests: XCTestCase {
    private let owner = "0x1a642f0e3c3af545e7acbd38b07251b3990914f1"
    private let recipient = "0x2222222222222222222222222222222222222222"
    private func request(_ extra: [String: Any] = [:]) throws -> WalletConnectEVMRequest {
        var object: [String: Any] = ["from": owner, "to": recipient, "value": "0x0"]
        object.merge(extra) { _, new in new }
        return try .init(params: JSONSerialization.data(withJSONObject: [object]), account: owner, chainID: 1)
    }
    func testExactTransactionFieldsAndEnvelope() throws {
        let data = "0x095ea7b3" + String(repeating: "0", count: 24) + String(recipient.dropFirst(2)) + String(repeating: "f", count: 64)
        let request = try request(["data": data, "chainId": "0x1", "gas": "0xea60", "nonce": "0x7", "type": "0x2", "maxFeePerGas": "0x3b9aca00", "maxPriorityFeePerGas": "0x1"])
        XCTAssertEqual(request.sender, owner); XCTAssertEqual(request.recipient, recipient)
        XCTAssertEqual(request.call.hex, data); XCTAssertEqual(request.gas, 60_000); XCTAssertEqual(request.nonce, 7)
        XCTAssertEqual(request.maxFeePerGas, 1_000_000_000); XCTAssertEqual(request.maxPriorityFeePerGas, 1)
        XCTAssertEqual(request.legacy, false)
        XCTAssertTrue(try self.request().call.bytes.isEmpty)
        XCTAssertEqual(try self.request(["gasPrice": "0x3b9aca00"]).legacy, true)
        XCTAssertEqual(try self.request(["value": "0x" + String(repeating: "f", count: 64)]).value,
                       "115792089237316195423570985008687907853269984665640564039457584007913129639935")
    }
    func testRejectsAmbiguousUnsupportedAndMismatchedRequests() throws {
        let bad: [[String: Any]] = [
            ["from": recipient], ["chainId": "0x2"], ["to": NSNull()], ["to": EVMPermissionRemoval.zero],
            ["value": 1], ["value": "1"], ["value": "0x00"], ["value": "0x-1"], ["value": "0x" + String(repeating: "f", count: 65)],
            ["data": "0x1"], ["data": "0xzz"], ["data": "0x01", "input": "0x02"], ["data": NSNull()],
            ["gas": "0x1"], ["gas": "0xea60", "gasLimit": "0xea61"],
            ["gasPrice": "0x1", "maxFeePerGas": "0x2"], ["maxPriorityFeePerGas": "0x2"],
            ["maxFeePerGas": "0x1", "maxPriorityFeePerGas": "0x2"],
            ["type": "0x3"], ["type": "0x4"], ["type": "0x0", "maxFeePerGas": "0x2"], ["type": "0x2", "gasPrice": "0x2"],
            ["authorizationList": []], ["accessList": [["address": recipient, "storageKeys": []]]], ["blobVersionedHashes": []],
            ["data": "0x" + String(repeating: "ab", count: 16_385)]
        ]
        for item in bad { XCTAssertThrowsError(try request(item), String(describing: item.keys)) }
        XCTAssertThrowsError(try WalletConnectEVMRequest(params: Data("[]".utf8), account: owner, chainID: 1))
    }
    func testContractSignatureBindsAllBytesAndKeepsZeroValueCalls() throws {
        let call = try EVMContractCall(hex: "0x095ea7b3" + String(repeating: "00", count: 64))
        let plan = EVMSendPlan(network: .ethereum, sender: owner, recipient: recipient, reference: "native", decimals: 18,
            requestedAmount: "0", amount: "0", assetBalance: "1000000000000000000", nativeBalance: "1000000000000000000",
            nonce: 7, gasLimit: 60_000, maxFeePerGas: 1_000_000_000, maxPriorityFeePerGas: 1,
            blockHeight: 100, call: call)
        try plan.validate()
        let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
        try EVMSendCrypto.verify(signed, plan: plan)
        XCTAssertEqual(try EVMSendCrypto.data(plan), call.bytes)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        json["call"] = ["bytes": Data([0x01]).base64EncodedString()]
        let altered = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try EVMSendCrypto.verify(signed, plan: altered))
        json["call"] = nil
        let dropped = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try dropped.validate())
    }
}

@MainActor final class WalletConnectEVMQuoteTests: XCTestCase {
    private let owner = "0x1a642f0e3c3af545e7acbd38b07251b3990914f1"
    private let recipient = "0x2222222222222222222222222222222222222222"
    private func input(_ network: EVMSendNetwork, extra: [String: String] = [:]) throws -> WalletConnectEVMRequest {
        var object = ["from": owner, "to": recipient, "value": "0x0", "data": "0x095ea7b3" + String(repeating: "00", count: 64)]
        object.merge(extra) { _, value in value }
        return try .init(params: JSONSerialization.data(withJSONObject: [object]), account: owner, chainID: network.chainID)
    }
    func testEveryNetworkQuotesSignsAndChecksContractBytes() async throws {
        for network in EVMSendNetwork.allCases {
            let transport = EVMSendFixtureTransport(network: network)
            let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://test.example")!], transport: transport)
            let request = try input(network)
            let plan = try await client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18, amount: "0", request: request)
            XCTAssertEqual(plan.call, request.call); XCTAssertEqual(plan.value, "0")
            try await client.preflight(plan)
            let signed = try EVMSendCrypto.sign(plan, privateKey: Data(repeating: 1, count: 32))
            await transport.configure(plan, signed)
            let result = try await client.submit(signed, plan: plan, reconcileFirst: false)
            XCTAssertEqual(result.outcome, .accepted)
        }
    }
    func testExplicitTransactionFeesAndNonceAreNeverSilentlyChanged() async throws {
        let transport = EVMSendFixtureTransport(network: .ethereum)
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://test.example")!], transport: transport)
        let fields = ["gas": "0xea60", "nonce": "0x7", "maxFeePerGas": "0xba43b7400", "maxPriorityFeePerGas": "0x77359400", "type": "0x2"]
        let request = try input(.ethereum, extra: fields)
        let plan = try await client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18, amount: "0", request: request)
        XCTAssertEqual(plan.gasLimit, request.gas); XCTAssertEqual(plan.nonce, request.nonce)
        XCTAssertEqual(plan.maxFeePerGas, request.maxFeePerGas); XCTAssertEqual(plan.maxPriorityFeePerGas, request.maxPriorityFeePerGas)
        for extra in [["nonce": "0x8"], ["maxFeePerGas": "0x1"], ["value": "0x3635c9adc5dea00000"]] {
            let bad = try input(.ethereum, extra: extra)
            do {
                _ = try await client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18, amount: bad.value, request: bad)
                XCTFail("Must reject changed nonce, insufficient fee or value plus fee")
            } catch {}
        }
    }
    func testFalseReturningTokenCallCannotBePresentedAsSuccessfulSimulation() async throws {
        let transport = EVMSendFixtureTransport("falseToken", network: .ethereum)
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://test.example")!], transport: transport)
        do {
            _ = try await client.quote(sender: owner, recipient: recipient, reference: "native", decimals: 18, amount: "0", request: input(.ethereum))
            XCTFail("False token approval must fail simulation")
        } catch { XCTAssertEqual(error as? EVMSendError, .simulationFailed) }
    }
}

final class WalletConnectApprovalEditingTests: XCTestCase {
    private let owner = "0x1a642f0e3c3af545e7acbd38b07251b3990914f1"
    private let target = "0x2222222222222222222222222222222222222222"
    private func input() throws -> WalletConnectEVMRequest {
        try .init(params: JSONEncoder().encode([["from": owner, "to": target, "value": "0x0", "chainId": "0x1",
            "data": "0x095ea7b3" + String(repeating: "0", count: 24) + String(target.dropFirst(2)) + String(repeating: "f", count: 64),
            "gas": "0xea60", "nonce": "0x7", "type": "0x2", "maxFeePerGas": "0x3b9aca00", "maxPriorityFeePerGas": "0x1"]]), account: owner, chainID: 1)
    }
    func testLimitChangeBindsSpenderValueChainAndEnvelope() throws {
        let original = try input(), changed = try original.replacingApprovalAmount("1234567")
        XCTAssertEqual(original.call.bytes.prefix(36), changed.call.bytes.prefix(36))
        XCTAssertEqual(changed.sender, original.sender); XCTAssertEqual(changed.recipient, original.recipient)
        XCTAssertEqual(changed.value, "0"); XCTAssertEqual(changed.chainID, original.chainID)
        XCTAssertEqual(changed.gas, original.gas); XCTAssertEqual(changed.nonce, original.nonce)
        XCTAssertEqual(changed.maxFeePerGas, original.maxFeePerGas); XCTAssertEqual(changed.maxPriorityFeePerGas, original.maxPriorityFeePerGas)
        XCTAssertEqual(changed.legacy, original.legacy)
        XCTAssertEqual(WalletConnectEVMAction(changed).fields.last?.value, "1234567")
        XCTAssertEqual(try changed.replacingApprovalAmount(WalletConnectEVMAction.maximum), original)
        XCTAssertEqual(WalletConnectEVMAction(try original.replacingApprovalAmount("0")).fields.last?.value, "0")
        for invalid in ["-1", "01", "1.1", WalletConnectEVMAction.maximum + "0"] { XCTAssertThrowsError(try original.replacingApprovalAmount(invalid)) }
        let plan = EVMSendPlan(network: .ethereum, sender: owner, recipient: target, reference: "native", decimals: 18,
            requestedAmount: "0", amount: "0", assetBalance: "1000000000000000000", nativeBalance: "1000000000000000000",
            nonce: 7, gasLimit: 60000, maxFeePerGas: 1_000_000_000, maxPriorityFeePerGas: 1, blockHeight: 1, call: changed.call)
        XCTAssertFalse(original.matches(plan)); XCTAssertTrue(original.matchesCommittedApproval(plan)); XCTAssertTrue(changed.matches(plan))
        var wrong = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        wrong["recipient"] = owner
        XCTAssertFalse(original.matchesCommittedApproval(try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject: wrong))))
    }
    func testMetadataRequiresERC20AndRejectsNFTAndMissingMethods() async throws {
        for mode in ["token", "nft", "absent", "malformed", "provider"] {
            let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://test.example")!], transport: ApprovalProbeTransport(mode: mode))
            do {
                let token = try await client.walletConnectApprovalToken(input())
                if mode == "token" { XCTAssertEqual(token?.decimals, 6); XCTAssertEqual(token?.balance, "250000000"); XCTAssertEqual(token?.allowance, "0") }
                else if mode == "provider" { XCTFail("Provider errors cannot masquerade as absent metadata") }
                else { XCTAssertNil(token, mode) }
            } catch { XCTAssertEqual(mode, "provider") }
        }
    }
}
private actor ApprovalProbeTransport: AnkrTransport {
    let mode: String
    init(mode: String) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let batch = try JSONDecoder().decode([SolanaJSON].self, from: request.httpBody!)
        let rows: [SolanaJSON] = batch.map { item in
            var reply: [String: SolanaJSON] = ["id": item["id"], "jsonrpc": .string("2.0")]
            if item["method"].string == "eth_chainId" { reply["result"] = .string("0x1") }
            else {
                let data = item["params"].array![0]["data"].string!
                if mode == "provider" { reply["error"] = .object(["code": .number("-32005"), "message": .string("Rate limit")]) }
                else if mode == "absent" || (data.hasPrefix("0x01ffc9a7") && mode != "nft") {
                    reply["error"] = .object(["code": .number("3"), "message": .string("execution reverted")])
                } else if mode == "malformed" { reply["result"] = .string("0x00") }
                else {
                    let n: UInt64 = data.hasPrefix("0x313ce567") ? 6 : data.hasPrefix("0x70a08231") ? 250000000 : data.hasPrefix("0x01ffc9a7") ? 1 : 0
                    reply["result"] = .string("0x" + String(repeating: "0", count: 64 - String(n, radix: 16).count) + String(n, radix: 16))
                }
            }
            return .object(reply)
        }
        return (try JSONEncoder().encode(rows), 200)
    }
}
