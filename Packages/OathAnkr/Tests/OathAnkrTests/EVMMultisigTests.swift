import XCTest
@testable import OathAnkr

private struct SafeLocalTransport: AnkrTransport {
    func send(_ original: URLRequest) async throws -> (Data, Int) {
        var request = original; request.url = URL(string: "http://127.0.0.1:18547")!
        return try await AnkrHTTPTransport().send(request)
    }
}
@MainActor final class EVMMultisigTests: XCTestCase {
    private let executor = Data(repeating: 9, count: 32)
    private func keys(_ n: Int) -> [Data] { (1...n).map { Data(repeating: UInt8(20 + $0), count: 32) } }
    private func policy(_ m: Int, _ n: Int) throws -> EVMMultisigPolicy {
        try .init(required: m, owners: keys(n).map { try EVMSendCrypto.address(privateKey: $0) }, salt: Data(repeating: UInt8(m * 16 + n), count: 32), executor: EVMSendCrypto.address(privateKey: executor))
    }
    private func plan(_ policy: EVMMultisigPolicy, network: EVMSendNetwork = .ethereumSepolia) throws -> EVMSendPlan {
        .init(network: network, sender: try policy.address, recipient: "0x" + String(repeating: "a", count: 40), reference: "native", decimals: 18,
            requestedAmount: "100", amount: "100", assetBalance: "1000", nativeBalance: "1000", nonce: 0, gasLimit: 400_000, maxFeePerGas: 1_000_000_000,
            maxPriorityFeePerGas: 1, blockHeight: 100, multisig: .init(policy: policy, safeNonce: 0, executorBalance: "1000000000000000000"))
    }
    func testThresholdSignatureBindingAndRecovery() throws {
        for (m,n) in [(1,2),(2,3),(3,5),(10,15),(15,15)] {
            let policy = try policy(m,n), p = try plan(policy)
            let signed = try EVMMultisigCrypto.sign(p, keys: Array(keys(n).suffix(m)), executorKey: executor)
            try EVMSendCrypto.verify(signed, plan: p)
            XCTAssertEqual(signed.multisigSignatures?.count, m * 65)
            XCTAssertEqual(p.remaining, "900") // Gas belongs to the separate executor.
            XCTAssertThrowsError(try EVMMultisigCrypto.sign(p, keys: Array(keys(n).prefix(m-1)), executorKey: executor))
            XCTAssertThrowsError(try EVMMultisigCrypto.sign(p, keys: [keys(n)[0], keys(n)[0]], executorKey: executor))
            XCTAssertThrowsError(try EVMMultisigCrypto.sign(p, keys: keys(n), executorKey: Data(repeating: 8, count: 32)))
            XCTAssertThrowsError(try EVMSendCrypto.sign(p, privateKey: keys(n)[0]))
            XCTAssertThrowsError(try EVMSendCrypto.verify(signed, plan: plan(policy, network: .ethereum)))
            let encoded = try JSONEncoder().encode(p)
            XCTAssertEqual(try JSONDecoder().decode(EVMSendPlan.self, from: encoded), p)
            let recovered = try JSONDecoder().decode(EVMSignedSend.self, from: JSONEncoder().encode(signed))
            try EVMSendCrypto.verify(recovered, plan: p)
        }
    }
    func testNetworkBindingTamperingAndExecutorAccounting() throws {
        let policy = try policy(2,3)
        for network in EVMSendNetwork.allCases {
            let p = try plan(policy, network: network)
            let signed = try EVMMultisigCrypto.sign(p, keys: keys(3), executorKey: executor)
            try EVMSendCrypto.verify(signed, plan: p)
            let commitment = try EVMSendReservation(plan: p, hash: signed.hash)
            XCTAssertEqual(commitment.nativeCost, p.amount)
            XCTAssertTrue(commitment.requiresPendingState)
            for field in ["recipient", "amount", "nonce"] {
                var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String:Any])
                json[field] = field == "recipient" ? "0x" + String(repeating:"b", count:40) : field == "amount" ? "99" : 1
                let changed = try JSONDecoder().decode(EVMSendPlan.self, from: JSONSerialization.data(withJSONObject:json))
                XCTAssertThrowsError(try EVMSendCrypto.verify(signed,plan:changed))
            }
            if network != .ethereum {
                XCTAssertThrowsError(try EVMSendCrypto.verify(signed,plan:plan(policy,network:.ethereum)))
            }
        }
        XCTAssertEqual(EVMSendNetwork.arc.symbol,"USDC")
        XCTAssertEqual(EVMSendNetwork.arc.chainID,5042)
    }
    func testRejectMalformedPolicies() throws {
        let p = try policy(2,3)
        XCTAssertThrowsError(try EVMMultisigPolicy(required: 4, owners: p.owners, salt: p.salt, executor: p.executor))
        XCTAssertThrowsError(try EVMMultisigPolicy(required: 0, owners: p.owners, salt: p.salt, executor: p.executor))
        XCTAssertThrowsError(try EVMMultisigPolicy(required: 2, owners: [p.owners[0],p.owners[0]], salt: p.salt, executor: p.executor))
        XCTAssertThrowsError(try EVMMultisigPolicy(required: 2, owners: p.owners, salt: p.salt, executor: p.owners[0]))
        XCTAssertThrowsError(try EVMMultisigPolicy(required: 2, owners: p.owners, salt: Data(), executor: p.executor))
    }
    func testSafeExecutionNativeTokensThresholdsAndReplays() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SAFE_LOCAL"] == "1" else { throw XCTSkip("Opt-in local EVM execution") }
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: "/tmp/oath-safe-local.json"))) as? [String:String])
        let client = try EVMSendClient(network: .ethereumSepolia, endpoints: [URL(string: "https://local.example")!], transport: SafeLocalTransport())
        _ = try await client.rpc("evm_mine", [])
        let token = try XCTUnwrap(fixture["Token"]), recipient = "0x" + String(repeating: "a", count: 40)
        for (m,n) in [(1,2),(2,3),(3,5),(10,15),(15,15)] {
            let policy = try policy(m,n), address = try policy.address
            print("SAFE_STAGE quote setup")
            let setup = try await client.quoteMultisig(policy: policy, recipient: EVMMultisigPolicy.factory, reference: "native", decimals: 18, amount: "0", setup: true)
            print("SAFE_STAGE sign setup")
            let deployed = try EVMMultisigCrypto.sign(setup, keys: [], executorKey: executor)
            print("SAFE_STAGE validate setup")
            try await client.validateSignedMultisig(deployed, plan: setup)
            _ = try await client.submit(deployed, plan: setup, reconcileFirst: false)
            print("SAFE_STAGE deployment status")
            let deployment = try await client.status(deployed, plan: setup)
            XCTAssertEqual(deployment.outcome, .confirmed)
            print("SAFE_STAGE read state")
            let state = try await client.multisigState(policy); XCTAssertTrue(state.configured); XCTAssertEqual(state.nonce, 0)
            // Test-only local faucet and mint. Wallet signing/submission uses production code.
            _ = try await client.rpc("evm_setAccountBalance", [.string(address), .string("0x10000000000000000")])
            let mint = try SafeABI.selector("mint(address,uint256)") + SafeABI.address(address) + SafeABI.uint(1_000_000)
            _ = try await client.rpc("eth_sendTransaction", [.object(["from": .string(policy.executor), "to": .string(token), "data": .string("0x" + TronSendCrypto.hex(mint)), "gas": .string("0x186a0")])])
            do {
                _ = try await client.quoteMultisig(policy: policy, recipient: recipient, reference: try XCTUnwrap(fixture["FalseToken"]), decimals: 6, amount: "1")
                XCTFail("False-return token must not be approved")
            } catch { XCTAssertEqual(error as? EVMSendError, .simulationFailed) }
            do {
                _ = try await client.quoteMultisig(policy: policy, recipient: try XCTUnwrap(fixture["Reject"]), reference: "native", decimals: 18, amount: "1")
                XCTFail("Reverting recipient must not be approved")
            } catch { guard case EVMSendError.rpc = error else { return XCTFail("Unexpected rejection class") } }
            for (ref,maximum) in [("native",false),(token,false),(token,true),("native",true)] {
                let before = try await client.balance(owner: recipient, reference: ref)
                let funds = try await client.balance(owner: address, reference: ref)
                let payerBefore = try await client.balance(owner: policy.executor, reference: "native")
                let p = try await client.quoteMultisig(policy: policy, recipient: recipient, reference: ref, decimals: ref == "native" ? 18:6, amount: "123", maximum: maximum)
                let s = try EVMMultisigCrypto.sign(p, keys: Array(keys(n).suffix(m)), executorKey: executor)
                try await client.validateSignedMultisig(s, plan: p)
                _ = try await client.submit(s, plan: p, reconcileFirst: false)
                let receipt = try await client.status(s, plan: p)
                XCTAssertEqual(receipt.outcome, .confirmed)
                let after = try await client.balance(owner: recipient, reference: ref), balance = try await client.balance(owner: address, reference: ref)
                let payerAfter = try await client.balance(owner: policy.executor, reference: "native")
                XCTAssertEqual(try EVMSendAmount.subtract(after,before), p.amount)
                XCTAssertEqual(try EVMSendAmount.subtract(funds,balance), p.amount)
                XCTAssertEqual(try EVMSendAmount.subtract(payerBefore,payerAfter), String(try XCTUnwrap(receipt.fee)))
                if ref != "native" { XCTAssertEqual(receipt.deliveredAmount,p.amount) }
                if maximum { XCTAssertEqual(balance,"0") }
                let duplicate = try await client.submit(s, plan: p)
                XCTAssertEqual(duplicate.outcome,.confirmed)
                let unchanged = try await client.balance(owner: recipient, reference: ref); XCTAssertEqual(unchanged,after)
                print("SAFE_LOCAL_CONFIRMED threshold=\(m)/\(n) token=\(ref != "native") maximum=\(maximum) exact_balance_delta=true")
            }
            // A Safe modified outside Oath must never retain its old trusted policy.
            for slot in ["0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8", "0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5"] {
                let original = try await client.rpc("eth_getStorageAt", [.string(address),.string(slot),.string("latest")])
                _ = try await client.rpc("evm_setAccountStorageAt", [.string(address),.string(slot),.string("0x" + String(repeating:"0",count:63) + "1")])
                do { _ = try await client.multisigState(policy); XCTFail("Altered guard/fallback trusted") }
                catch { XCTAssertEqual(error as? EVMSendError,.changed) }
                _ = try await client.rpc("evm_setAccountStorageAt", [.string(address),.string(slot),.string(original.string == "0x" ? "0x" + String(repeating:"0",count:64) : original.string!)])
            }
        }
    }
}
