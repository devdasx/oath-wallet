import XCTest
@testable import OathAnkr

@MainActor final class ThorchainMultisigLiveTests: XCTestCase {
    struct Funding: Decodable { let privateKey: String, publicKey: String, sender: String, recipient: String }
    struct Fixture: Decodable {
        struct Signer: Decodable { let key: String, publicKey: String }
        struct Policy: Decodable { let required: Int, count: Int, address: String, mainnetAddress: String, amino: String }
        let signers: [Signer], policies: [Policy]
    }
    func testRealTHORNodeThresholdAndTokenMatrix() async throws {
        guard let fundingPath = ProcessInfo.processInfo.environment["OATH_THORCHAIN_SEND_FIXTURE"],
              let fixturePath = ProcessInfo.processInfo.environment["OATH_THORCHAIN_MULTISIG_FIXTURE"] else { throw XCTSkip("Opt-in isolated THORNode execution") }
        let funding = try JSONDecoder().decode(Funding.self, from: Data(contentsOf: URL(fileURLWithPath: fundingPath)))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let client = try ThorchainSendClient(network: .localTestnet, localAPI: URL(string: "http://127.0.0.1:28317")!, localRPC: URL(string: "http://127.0.0.1:28657")!)
        var evidence = [[String:String]](), vectors = [[String:String]]()
        func confirmed(_ signed: ThorchainSignedSend, _ plan: ThorchainSendPlan) async throws -> ThorchainSendReceipt {
            _ = try await client.submit(signed, plan: plan, reconcileFirst: false)
            for _ in 0..<90 {
                try await Task.sleep(for: .seconds(1))
                let r = try await client.status(signed, plan: plan)
                if r.outcome == .confirmed { return r }
                if [.failed,.expired,.replaced].contains(r.outcome) { XCTFail("Transaction did not confirm: \(r.outcome)"); throw ThorchainSendError.execution }
            }
            XCTFail("Confirmation timed out"); throw ThorchainSendError.transport
        }
        for spec in fixture.policies {
            let policy = try ThorchainMultisigPolicy(required: spec.required, publicKeys: fixture.signers.prefix(spec.count).map { try TronIdentity.hex($0.publicKey) })
            XCTAssertEqual(policy.address(network: .localTestnet), spec.address)
            XCTAssertEqual(policy.address(network: .mainnet), spec.mainnetAddress)
            XCTAssertEqual(TronSendCrypto.hex(policy.aminoPublicKey), spec.amino)
            // Only the 2-of-3 account needs all token variants; every other
            // threshold executes native RUNE using a different signer subset.
            let refs = spec.count == 3 ? ["native","tcy","x/ruji","x/oath-test"] : ["native"]
            for reference in refs {
                let decimals = reference == "x/oath-test" ? 6 : 8
                let fundingPlan = try await client.quote(sender: funding.sender, recipient: spec.address, reference: reference,
                    publicKey: TronIdentity.hex(funding.publicKey), decimals: decimals, amount: reference == "native" ? "200000000" : "1000000")
                _ = try await confirmed(ThorchainSendCrypto.sign(fundingPlan, privateKey: TronIdentity.hex(funding.privateKey)), fundingPlan)
                let before = try await client.balance(owner: funding.recipient, reference: reference)
                let nativeBefore = try await client.balance(owner: spec.address, reference: "native")
                let p = try await client.quote(sender: spec.address, recipient: funding.recipient, reference: reference,
                    publicKey: policy.aminoPublicKey, decimals: decimals, amount: "12345", memo: "Oath multisig <&> ✓", multisig: policy)
                try await client.preflight(p)
                let keys = try fixture.signers.prefix(spec.count).reversed().prefix(spec.required).map { try TronIdentity.hex($0.key) }
                let signed = try ThorchainSendCrypto.sign(p, privateKeys: keys)
                let receipt = try await confirmed(signed, p)
                let after = try await client.balance(owner: funding.recipient, reference: reference)
                let nativeAfter = try await client.balance(owner: spec.address, reference: "native")
                XCTAssertEqual(try ThorchainSendAmount.subtract(after,before), p.amount)
                XCTAssertEqual(try ThorchainSendAmount.subtract(nativeBefore,nativeAfter),try ThorchainSendAmount.add(String(p.fee),reference == "native" ? p.amount : "0"))
                XCTAssertEqual(receipt.fee,p.fee); XCTAssertNotNil(receipt.timestamp)
                let replay = try await client.submit(signed,plan:p); XCTAssertEqual(replay.outcome,.confirmed)
                evidence.append(["threshold":"\(spec.required)-of-\(spec.count)","reference":reference,"hash":signed.hash,"height":String(receipt.height ?? 0),"fee":String(p.fee),"recipientDelta":p.amount])
                vectors.append(["plan":String(decoding:try JSONEncoder().encode(p),as:UTF8.self),"signDoc":try ThorchainSendCrypto.multisigSignDoc(p).base64EncodedString(),"wire":signed.bytes.base64EncodedString()])
                try JSONEncoder().encode(evidence).write(to:URL(fileURLWithPath:"/tmp/oath-thor-multisig-live-evidence.json"))
                // Local verification data only, never diagnostic upload or Git.
                try JSONEncoder().encode(vectors).write(to:URL(fileURLWithPath:"/tmp/oath-thor-multisig-vectors.json"))
                print("Confirmed THORNode \(spec.required)-of-\(spec.count) \(reference); balances, fee, history, replay checked.")
            }
        }
        XCTAssertEqual(evidence.count,10)
    }
}


extension ThorchainMultisigLiveTests {
    func testRealTHORNodeReplacementAndUnusedExpiry() async throws {
        guard let fundingPath = ProcessInfo.processInfo.environment["OATH_THORCHAIN_SEND_FIXTURE"],
              let fixturePath = ProcessInfo.processInfo.environment["OATH_THORCHAIN_MULTISIG_FIXTURE"] else { throw XCTSkip("Opt-in isolated THORNode execution") }
        let funding = try JSONDecoder().decode(Funding.self, from: Data(contentsOf: URL(fileURLWithPath: fundingPath)))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: fixturePath)))
        let client = try ThorchainSendClient(network: .localTestnet, localAPI: URL(string: "http://127.0.0.1:28317")!, localRPC: URL(string: "http://127.0.0.1:28657")!)
        let policy = try ThorchainMultisigPolicy(required: 2, publicKeys: fixture.signers.prefix(3).map { try TronIdentity.hex($0.publicKey) })
        let keys = try fixture.signers.prefix(2).map { try TronIdentity.hex($0.key) }
        func quote(_ amount: String) async throws -> ThorchainSendPlan {
            try await client.quote(sender: policy.address(network: .localTestnet), recipient: funding.recipient,
                reference: "native", publicKey: policy.aminoPublicKey, decimals: 8, amount: amount, multisig: policy)
        }
        // Fund independently so this test also runs against a fresh fixture.
        let fundingPlan = try await client.quote(sender: funding.sender, recipient: policy.address(network: .localTestnet),
            reference: "native", publicKey: TronIdentity.hex(funding.publicKey), decimals: 8, amount: "100000000")
        let fundingSigned = try ThorchainSendCrypto.sign(fundingPlan, privateKey: TronIdentity.hex(funding.privateKey))
        _ = try await client.submit(fundingSigned, plan: fundingPlan, reconcileFirst: false)
        var funded = try await client.status(fundingSigned, plan: fundingPlan)
        for _ in 0..<60 where funded.outcome != .confirmed {
            try await Task.sleep(for: .seconds(1))
            funded = try await client.status(fundingSigned, plan: fundingPlan)
        }
        XCTAssertEqual(funded.outcome, .confirmed)
        let p = try await quote("1234"), original = try ThorchainSendCrypto.sign(p, privateKeys: keys)
        let replacementPlan = try await quote("1235"), replacement = try ThorchainSendCrypto.sign(replacementPlan, privateKeys: keys)
        XCTAssertEqual(p.sequence, replacementPlan.sequence)
        _ = try await client.submit(replacement, plan: replacementPlan, reconcileFirst: false)
        var receipt = try await client.status(replacement, plan: replacementPlan)
        for _ in 0..<60 where receipt.outcome != .confirmed {
            try await Task.sleep(for: .seconds(1))
            receipt = try await client.status(replacement, plan: replacementPlan)
        }
        XCTAssertEqual(receipt.outcome, .confirmed)
        let replaced = try await client.status(original, plan: p)
        XCTAssertEqual(replaced.outcome, .replaced)
        XCTAssertEqual(replaced.replacementHash, replacement.hash)
        let unusedPlan = try await quote("1234"), unused = try ThorchainSendCrypto.sign(unusedPlan, privateKeys: keys)
        let before = try await client.balance(owner: unusedPlan.sender, reference: "native")
        var expired = try await client.status(unused, plan: unusedPlan)
        for _ in 0..<90 where expired.outcome != .expired {
            try await Task.sleep(for: .seconds(1))
            expired = try await client.status(unused, plan: unusedPlan)
        }
        XCTAssertEqual(expired.outcome, .expired)
        let after = try await client.balance(owner: unusedPlan.sender, reference: "native")
        XCTAssertEqual(before, after)
        let evidence = ["replacementHash": replacement.hash, "replacementOutcome": replaced.outcome.rawValue,
            "unusedOutcome": expired.outcome.rawValue, "unusedBalanceUnchanged": String(before == after)]
        try JSONEncoder().encode(evidence).write(to: URL(fileURLWithPath: "/tmp/oath-thor-multisig-recovery-evidence.json"))
        print("Confirmed THORNode multisig replacement and unused expiry; no balance change for expired intent.")
    }
}
