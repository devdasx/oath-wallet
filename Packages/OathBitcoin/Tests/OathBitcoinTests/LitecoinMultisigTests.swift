import XCTest
@testable import OathBitcoin

final class LitecoinMultisigTests: XCTestCase {
    // Deterministic test-only scalars/seeds. Never used for funded wallets.
    func fixed(_ n: UInt8) throws -> BitcoinMultisigKey {
        .wif(try LitecoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([n]), compressed: true))
    }
    func testSortedPolicyAndPublicOnlyDescriptors() throws {
        let keys = try [fixed(1), fixed(2), fixed(3)]
        let a = try BitcoinMultisig.wallet(required: 2, keys: keys, network: .litecoin)
        let b = try BitcoinMultisig.wallet(required: 2, keys: keys.reversed(), network: .litecoin)
        let first = try BitcoinKeys.addresses(branch: a.branches[0], range: 0..<1)[0]
        XCTAssertEqual(first.address, try BitcoinKeys.addresses(branch: b.branches[0], range: 0..<1)[0].address)
        XCTAssertTrue(first.script.hasPrefix("0020"))
        XCTAssertTrue(first.address.hasPrefix("ltc1q"))
        XCTAssertEqual(a.network, .litecoin)
        XCTAssertEqual(a.branches[0].path, "m/48'/2'/0'/2'/0")
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF(BitcoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: true), network: .litecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 2, keys: keys))
        for env in [BitcoinSendNetwork.mainnet, .testnet, .regtest] {
            let encoded = try BitcoinSendPlan.address(first, on: env, chain: .litecoin)
            XCTAssertEqual(try BitcoinSendPlan.recipientScript(encoded, chain: .litecoin, network: env), Data(hex: first.script))
        }
        XCTAssertNotNil(first.multisigInputWeight)
        XCTAssertFalse(a.branches[0].isHD)
        for key in keys { if case .wif(let text) = key { XCTAssertFalse(a.branches[0].descriptor.contains(text)) } }
    }
    func testThresholdDuplicatesAndWIFValidation() throws {
        let keys = try [fixed(1), fixed(2)]
        for threshold in [0, 3] { XCTAssertThrowsError(try BitcoinMultisig.wallet(required: threshold, keys: keys, network: .litecoin)) }
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 1, keys: [keys[0]], network: .litecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 2, keys: [keys[0], keys[0]], network: .litecoin))
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF(String(repeating: "1", count: 64), network: .litecoin))
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF(LitecoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false), network: .litecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 1, keys: [.seed(Data(0..<32)), .seed(Data(0..<32))], network: .litecoin))
    }
    func testMixedAndHDKeysUseSeparateReceiveAndChangeBranches() throws {
        for keys in [try [fixed(1), .seed(Data(0..<32))], [.seed(Data(0..<32)), .seed(Data(32..<64))]] {
            let policy = try BitcoinMultisig.wallet(required: 2, keys: keys, network: .litecoin)
            XCTAssertEqual(policy.branches.count, 2)
            let addresses = try policy.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 0..<3) }
            XCTAssertEqual(Set(addresses.map(\.address)).count, 6)
            XCTAssertTrue(policy.branches.allSatisfy { !$0.descriptor.contains("prv") })
        }
    }
    func testEveryThresholdSignsWithBoundedFeesAndRejectsWrongChange() throws {
        for count in 2...15 {
            let keys = try (1...count).map { try fixed(UInt8($0)) }
            for required in 1...count {
                try checkSigning(required: required, keys: keys)
            }
        }
        try checkSigning(required: 2, keys: [fixed(1), .seed(Data(0..<32)), .seed(Data(32..<64))])
    }
    func testLitecoinCoreMultisigConsensus() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_LTC_MULTISIG_REGTEST_DIR"] else {
            throw XCTSkip("Isolated Litecoin Core regtest is opt-in")
        }
        let rpc = LitecoinMultisigCoreRPC(directory: directory)
        let mining = try await rpc.call("getnewaddress", []) as! String
        _ = try await rpc.call("generatetoaddress", [101, mining])
        var policies: [(Int, [BitcoinMultisigKey])] = try (2...15).flatMap { count in
            let keys = try (1...count).map { try fixed(UInt8($0)) }
            return (1...count).map { ($0, keys) }
        }
        policies += try [(2, [.seed(Data(0..<32)), .seed(Data(32..<64))]),
                         (2, [fixed(6), .seed(Data(64..<96)), .seed(Data(96..<128))])]

        for (required, keys) in policies {
            let policy = try BitcoinMultisig.wallet(required: required, keys: keys, network: .litecoin)
            // Multiple receive indices and a change input exercise distinct signing passes.
            let addresses = try policy.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 0..<($0.isHD ? 3 : 1)) }
            let outputs = try Dictionary(uniqueKeysWithValues: addresses.map { (try BitcoinSendPlan.address($0, on: .regtest, chain: .litecoin), "0.001") })
            let funding = try await rpc.call("sendmany", ["", outputs, 1, "", [], true]) as! String
            _ = try await rpc.call("generatetoaddress", [1, mining])
            let raw = Data(hex: try await rpc.call("getrawtransaction", [funding]) as! String)!
            let funded = try BitcoinTransactions.details(raw, network: .litecoin).outputs
            let coins = addresses.map { address in
                BitcoinSendCoin(accountID: "fixture", txid: funding, vout: funded.firstIndex { $0.script == address.script }!,
                    value: 100_000, address: address, previousTransaction: raw)
            }
            let changeBranch = policy.branches.last!
            let change = try BitcoinKeys.addresses(branch: changeBranch, range: (changeBranch.isHD ? 7..<8 : 0..<1))[0]
            let recipient = try await rpc.call("getnewaddress", []) as! String
            let plan = try BitcoinSendPlan.make(coins: coins, recipient: recipient, amount: Int64(coins.count) * 100_000 - 5_000,
                change: change, ratePerKVByte: 2000, network: .regtest, chain: .litecoin)
            XCTAssertEqual(plan.coins.count, coins.count)
            let signed = try BitcoinMultisig.sign(plan, required: required, keys: keys, network: .litecoin)
            let accepted = try await rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
            XCTAssertTrue(accepted[0]["allowed"] as? Bool == true, "Core rejected a multisig fixture")
            let hash = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as! String
            XCTAssertEqual(hash, signed.txid)
            _ = try await rpc.call("generatetoaddress", [1, mining])
            let result = try await rpc.call("getrawtransaction", [hash, true]) as! [String: Any]
            XCTAssertGreaterThan(result["confirmations"] as! Int, 0)
            XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(plan.maximumVBytes))
        }
        print("Litecoin Core regtest: fixed, HD, mixed, 1-of-2, 2-of-3 and 15-of-15 multisig transactions accepted and mined")
    }
    private func checkSigning(required: Int, keys: [BitcoinMultisigKey]) throws {
        let policy = try BitcoinMultisig.wallet(required: required, keys: keys, network: .litecoin)
        let address = try BitcoinKeys.addresses(branch: policy.branches[0], range: 0..<1)[0]
        let change = try BitcoinKeys.addresses(branch: policy.branches.last!, range: 0..<1)[0]
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(100_000)) + BitcoinWire.vector(Data(hex: address.script)!) + BitcoinWire.little(UInt32(0))
        let coin = BitcoinSendCoin(accountID: "fixture", txid: try BitcoinTransactions.txid(raw, network: .litecoin), vout: 0, value: 100_000,
            address: address, previousTransaction: raw)
        let recipient = try BitcoinKeys.addresses(branch: LitecoinKeys.wallet(seed: Data(64..<96)).branches[0], range: 0..<1)[0]
        let plan = try BitcoinSendPlan.make(coins: [coin], recipient: recipient.address, amount: 50_000, change: change, ratePerKVByte: 2000, chain: .litecoin)
        let signed = try BitcoinMultisig.sign(plan, required: required, keys: keys, network: .litecoin)
        XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(plan.maximumVBytes))
        XCTAssertEqual(signed.fee, plan.fee)
        let wrongChange = try BitcoinSendPlan.make(coins: [coin], recipient: recipient.address, amount: 50_000, change: recipient, ratePerKVByte: 2000, chain: .litecoin)
        XCTAssertThrowsError(try BitcoinMultisig.sign(wrongChange, required: required, keys: keys, network: .litecoin))
        XCTAssertThrowsError(try BitcoinMultisig.sign(plan, required: required == 1 ? 2 : 1, keys: keys, network: .litecoin))
    }
}

private struct LitecoinMultisigCoreRPC {
    let directory: String
    func call(_ method: String, _ params: [Any]) async throws -> Any {
        let cookie = try String(contentsOfFile: directory + "/regtest/.cookie", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19556/wallet/oath-multisig-fixture")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "method":method, "params":params])
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let error = result["error"] as? [String: Any] {
            throw NSError(domain: "LitecoinMultisigCoreRPC." + method, code: error["code"] as? Int ?? -1)
        }
        return result["result"]!
    }
}
