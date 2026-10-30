import XCTest
@testable import OathAnkr

/// Explicit opt-in public Nile transfers only. Never accepts mainnet fixtures.
@MainActor final class TronMultisigLiveTests: XCTestCase {
    func testLiveNileUnfundedSetupReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRON_READ_ONLY"] == "1" else {
            throw XCTSkip("Opt-in Nile account and chain-parameter check, no signing or broadcast")
        }
        let policy = try TronMultisigPolicy(required: 2, signers: [22, 23, 24].map {
            try TronSendCrypto.address(privateKey: Data(repeating: UInt8($0), count: 32))
        })
        let client = try TronSendClient(network: .nile, transport: ReadOnlyNileMultisigTransport())
        let state = try await client.multisigState(owner: "TF2zUKgdzGVmJPJa7fPnDrduu9RzHuD7SF", policy: policy)
        XCTAssertFalse(state.configured)
        XCTAssertEqual(state.balance, 0)
        XCTAssertGreaterThan(state.permissionFee, 0)
        print("NILE read-only verification passed: unfunded setup detected; current permission fee SUN=\(state.permissionFee). No transaction signed or broadcast.")
    }

    func testLiveNileMixedSignersTransfersBalancesAndHistory() async throws {
        guard ProcessInfo.processInfo.environment["OATH_TRON_MULTISIG_LIVE"] == "1",
              let path = ProcessInfo.processInfo.environment["OATH_TRON_TESTNET_FIXTURE"] else {
            throw XCTSkip("Requires explicit opt-in and a funded disposable Nile multisig fixture")
        }
        let f = try JSONDecoder().decode(TronJSON.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard f["network"].string == "nile" else { throw TronSendError.wrongNetwork }
        let client = try TronSendClient(network: .nile)
        let history = try TronClient(apiKey: "testnet", network: .nile)
        let treasury = try XCTUnwrap(f["sender"].string), treasuryKey = try TronIdentity.hex(XCTUnwrap(f["key"].string))
        let recipient = try XCTUnwrap(f["recipient"].string), cases = try XCTUnwrap(f["multisigCases"].array)
        let tokens = ["1005416", "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"]
        // Fail before any spending if the intended matrix lacks funding.
        let funds = try await client.balance(owner: treasury, reference: "native")
        guard let funds = UInt64(funds), funds >= 1_300_000_000 else { throw TronSendError.insufficientFunds }
        for token in tokens {
            let amount = try await client.balance(owner: treasury, reference: token)
            guard let amount = UInt64(amount), amount >= UInt64(cases.count) * 2_000_000 else { throw TronSendError.insufficientFunds }
        }
        func execute(_ plan: TronSendPlan, keys: [Data]) async throws -> (TronSignedSend, TronSendReceipt) {
            XCTAssertEqual(plan.network, .nile)
            let signed = try TronSendCrypto.sign(plan, privateKeys: keys)
            var receipt = try await client.submit(signed, plan: plan)
            for _ in 0..<60 where receipt.requiresConfirmation {
                try await Task.sleep(for: .seconds(3))
                receipt = try await client.status(signed, plan: plan)
            }
            XCTAssertEqual(receipt.outcome, .confirmed)
            guard receipt.outcome == .confirmed else { throw TronSendError.execution }
            return (signed, receipt)
        }
        for c in cases {
            let address = try XCTUnwrap(c["address"].string), bootstrap = try TronIdentity.hex(XCTUnwrap(c["bootstrap"].string))
            let signers = try XCTUnwrap(c["signers"].array), required = Int(try XCTUnwrap(c["required"].integer))
            let keys = try signers.map { try TronIdentity.hex(XCTUnwrap($0["key"].string)) }
            let policy = try TronMultisigPolicy(required: required, signers: keys.map { try TronSendCrypto.address(privateKey: $0) })
            XCTAssertTrue(signers.contains { $0["source"].string == "phrase" })
            XCTAssertTrue(signers.contains { $0["source"].string == "hex" })
            if try await client.balance(owner: address, reference: "native") == "0" {
                _ = try await execute(client.quote(sender: treasury, recipient: address, reference: "native", decimals: 6, amount: "300000000"), keys: [treasuryKey])
            }
            if try await !client.multisigState(owner: address, policy: policy).configured {
                let setup = try await client.quote(sender: address, recipient: address, reference: "native", decimals: 6, amount: "0", multisigSetup: policy)
                _ = try await execute(setup, keys: [bootstrap])
            }
            let configured = try await client.multisigState(owner: address, policy: policy)
            XCTAssertTrue(configured.configured)
            guard configured.configured else { throw TronSendError.unsupportedAccount }
            for token in tokens {
                _ = try await execute(client.quote(sender: treasury, recipient: address, reference: token, decimals: 6, amount: "2000000"), keys: [treasuryKey])
            }
            for reference in ["native"] + tokens {
                async let before = client.balance(owner: recipient, reference: reference)
                async let payerBefore = client.balance(owner: address, reference: "native")
                let (balanceBefore, nativeBefore) = try await (before, payerBefore)
                let plan = try await client.quote(sender: address, recipient: recipient, reference: reference, decimals: 6, amount: "1234567", multisig: policy)
                XCTAssertThrowsError(try TronSendCrypto.sign(plan, privateKey: bootstrap))
                if required > 1 { XCTAssertThrowsError(try TronSendCrypto.sign(plan, privateKeys: Array(keys.prefix(required - 1)))) }
                let (signed, receipt) = try await execute(plan, keys: Array(keys.suffix(required)))
                let after = try await client.balance(owner: recipient, reference: reference)
                let nativeAfter = try await client.balance(owner: address, reference: "native")
                let fee = try XCTUnwrap(receipt.fee)
                XCTAssertEqual(StellarIdentity.sum(after, "-" + balanceBefore), plan.amount)
                XCTAssertEqual(StellarIdentity.sum(nativeBefore, "-" + nativeAfter), String(fee + (reference == "native" ? UInt64(plan.amount)! : 0)))
                XCTAssertLessThanOrEqual(fee, plan.fee)
                let retry = try await client.submit(signed, plan: plan)
                XCTAssertEqual(retry, receipt)
                let unchanged = try await client.balance(owner: recipient, reference: reference)
                XCTAssertEqual(unchanged, after)
                var found = false
                for _ in 0..<12 where !found {
                    let page = try await history.history(owner: address, stream: reference == tokens[1] ? .trc20 : .transactions,
                        start: Int64(plan.timestamp) - 60000, end: Int64(Date.now.timeIntervalSince1970 * 1000) + 60000, limit: 200)
                    found = page.hashes.contains(signed.hash)
                    if !found { try await Task.sleep(for: .seconds(5)) }
                }
                XCTAssertTrue(found, "Confirmed transfer must appear in the production history parser")
                let transaction = try await history.transaction(signed.hash)
                XCTAssertEqual(transaction.hash, signed.hash)
                print("NILE multisig \(required)-of-\(keys.count) \(reference == "native" ? "TRX" : reference == tokens[0] ? "TRC10" : "TRC20") confirmed hash=\(signed.hash) feeSUN=\(fee)")
            }
        }
    }
}

private struct ReadOnlyNileMultisigTransport: AnkrTransport {
    let base = AnkrHTTPTransport()
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        guard request.url?.host == "nile.trongrid.io",
              ["getblockbynum", "getaccount", "getchainparameters"].contains(request.url?.lastPathComponent ?? "") else {
            throw TronSendError.configuration
        }
        return try await base.send(request)
    }
}
