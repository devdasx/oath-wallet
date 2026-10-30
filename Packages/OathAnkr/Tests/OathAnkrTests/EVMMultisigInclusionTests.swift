import XCTest
@testable import OathAnkr

@MainActor final class EVMMultisigInclusionTests: XCTestCase {
    func testIncludedSafeRequiresInnerExecutionEvidence() async throws {
        let keys = [Data(repeating: 1, count: 32), Data(repeating: 2, count: 32)]
        let executor = Data(repeating: 9, count: 32)
        let policy = try EVMMultisigPolicy(required: 1, owners: keys.map(EVMSendCrypto.address),
            salt: Data(repeating: 3, count: 32), executor: EVMSendCrypto.address(privateKey: executor))
        let plan = EVMSendPlan(network: .base, sender: try policy.address, recipient: "0x" + String(repeating: "a", count: 40),
            reference: "native", decimals: 18, requestedAmount: "100", amount: "100", assetBalance: "1000", nativeBalance: "1000",
            nonce: 7, gasLimit: 400_000, maxFeePerGas: 41_000_000_000, maxPriorityFeePerGas: 1_000_000_000, blockHeight: 100,
            multisig: .init(policy: policy, safeNonce: 0, executorBalance: "1000000000000000000"))
        let signed = try EVMMultisigCrypto.sign(plan, keys: [keys[0]], executorKey: executor)
        let outer = try EVMMultisigCrypto.outer(plan, signatures: XCTUnwrap(signed.multisigSignatures))
        let transport = EVMSendFixtureTransport("unfinalized", network: .base)
        await transport.configure(outer, signed)
        let client = try EVMSendClient(network: .base, endpoints: [URL(string: "https://test.example")!], transport: transport)
        do {
            _ = try await client.status(signed, plan: plan)
            XCTFail("Outer execution alone cannot confirm a Safe transfer")
        } catch { XCTAssertEqual(error as? EVMSendError, .execution) }
        await transport.setReceiptLogs([.object([
            "address": .string(plan.sender),
            "topics": .array([
                .string("0x" + TronSendCrypto.hex(TronSendCrypto.keccak(Data("ExecutionSuccess(bytes32,uint256)".utf8)))),
                .string("0x" + (try TronSendCrypto.hex(EVMMultisigCrypto.digest(plan))))
            ]),
            "data": .string("0x" + String(repeating: "0", count: 64))
        ])])
        let result = try await client.status(signed, plan: plan)
        XCTAssertEqual(result.outcome, .accepted)
        XCTAssertEqual(result.inclusion?.succeeded, true)
        XCTAssertEqual(result.inclusion?.height, 101)
    }
}
