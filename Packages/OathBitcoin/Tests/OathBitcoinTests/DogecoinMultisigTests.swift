import XCTest
@testable import OathBitcoin

final class DogecoinMultisigTests: XCTestCase {
    // Deterministic test-only scalars/seeds. Never used for funded wallets.
    func fixed(_ n: UInt8) throws -> BitcoinMultisigKey {
        .wif(try DogecoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([n]), compressed: true))
    }
    func testSortedPolicyAndPublicOnlyDescriptors() throws {
        let keys = try [fixed(1), fixed(2), fixed(3)]
        let a = try BitcoinMultisig.wallet(required: 2, keys: keys, network: .dogecoin)
        let b = try BitcoinMultisig.wallet(required: 2, keys: keys.reversed(), network: .dogecoin)
        let first = try BitcoinKeys.addresses(branch: a.branches[0], range: 0..<1)[0]
        XCTAssertEqual(first.address, try BitcoinKeys.addresses(branch: b.branches[0], range: 0..<1)[0].address)
        XCTAssertTrue(first.script.hasPrefix("a914"))
        XCTAssertEqual(try Base58Check.decode(first.address).first, 22)
        XCTAssertEqual(a.network, .dogecoin)
        XCTAssertEqual(a.branches[0].path, "m/48'/3'/0'/0'/0")
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF(LitecoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: true), network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 2, keys: keys))
        for env in [BitcoinSendNetwork.mainnet, .testnet, .regtest] {
            let encoded = try BitcoinSendPlan.address(first, on: env, chain: .dogecoin)
            XCTAssertEqual(try BitcoinSendPlan.recipientScript(encoded, chain: .dogecoin, network: env), Data(hex: first.script))
        }
        let testAddress = try BitcoinSendPlan.address(first, on: .testnet, chain: .dogecoin)
        XCTAssertEqual(try Base58Check.decode(testAddress).first, 196)
        XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(testAddress, chain: .dogecoin, network: .mainnet))
        XCTAssertThrowsError(try BitcoinSendPlan.recipientScript(first.address, chain: .dogecoin, network: .testnet))
        XCTAssertNotNil(first.multisigInputWeight)
        XCTAssertFalse(a.branches[0].isHD)
        for key in keys { if case .wif(let text) = key { XCTAssertFalse(a.branches[0].descriptor.contains(text)) } }
    }
    func testThresholdDuplicatesAndWIFValidation() throws {
        let keys = try [fixed(1), fixed(2)]
        for threshold in [0, 3] { XCTAssertThrowsError(try BitcoinMultisig.wallet(required: threshold, keys: keys, network: .dogecoin)) }
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 1, keys: [keys[0]], network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 1, keys: (1...16).map { try fixed(UInt8($0)) }, network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 2, keys: [keys[0], keys[0]], network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF(String(repeating: "1", count: 64), network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.validateWIF(DogecoinKeys.wif(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false), network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.wallet(required: 1, keys: [.seed(Data(0..<32)), .seed(Data(0..<32))], network: .dogecoin))
    }
    func testMixedAndHDKeysUseSeparateReceiveAndChangeBranches() throws {
        for keys in [try [fixed(1), .seed(Data(0..<32))], [.seed(Data(0..<32)), .seed(Data(32..<64))]] {
            let policy = try BitcoinMultisig.wallet(required: 2, keys: keys, network: .dogecoin)
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
    func testDiscoveryRetainsSpentHistoryAndAggregatesMultisigBalances() async throws {
        for keys in [try [fixed(1), fixed(2)], try [fixed(1), .seed(Data(0..<32))]] {
            let policy = try BitcoinMultisig.wallet(required: 2, keys: keys, network: .dogecoin)
            let query = QueryFixture()
            var states: [String: BitcoinAddressState] = [:]
            for branch in policy.branches {
                let address = try BitcoinKeys.addresses(branch: branch, range: branch.isHD ? 19..<20 : 0..<1)[0]
                states[address.scriptHash] = .init(confirmed: 100_000_000, unconfirmed: 0,
                    history: [.init(txid: String(repeating: "1", count: 64), height: 100)],
                    unspent: [.init(txid: String(repeating: "1", count: 64), vout: Int(branch.change), value: 100_000_000, height: 100)])
            }
            await query.configure(states)
            let scan = try await BitcoinDiscovery(query: query).scan(policy)
            try scan.validate(wallet: policy, requiredThrough: [:])
            XCTAssertEqual(scan.total, Int64(policy.branches.count) * 100_000_000)
            XCTAssertEqual(scan.addresses.count, policy.branches[0].isHD ? 80 : 1)
            XCTAssertTrue(scan.addresses.allSatisfy { $0.address.multisigInputWeight != nil })
            states = states.mapValues { .init(confirmed: 0, unconfirmed: 0, history: $0.history, unspent: []) }
            await query.configure(states)
            let spent = try await BitcoinDiscovery(query: query).scan(policy)
            XCTAssertEqual(spent.total, 0)
            XCTAssertEqual(spent.addresses.count, scan.addresses.count)
            XCTAssertEqual(spent.addresses.flatMap { $0.state.history }.count, policy.branches.count)
        }
    }
    func testMaximumPolicySignsAcrossDogecoinFeeRange() throws {
        let keys = try (1...15).map { try fixed(UInt8($0)) }
        for rate: Int64 in [1_000_000, 50_657_312, 100_000_000] {
            try checkSigning(required: 15, keys: keys, rate: rate)
        }
    }
    func testDogecoinCoreMultisigConsensus() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_DOGE_MULTISIG_REGTEST_DIR"] else {
            throw XCTSkip("Isolated Dogecoin Core regtest is opt-in")
        }
        let rpc = DogecoinMultisigCoreRPC(directory: directory)
        let info = try await rpc.call("getblockchaininfo", []) as! [String: Any]
        XCTAssertEqual(info["chain"] as? String, "regtest")
        _ = try await rpc.call("generate", [241])
        var policies: [(Int, [BitcoinMultisigKey])] = try (2...15).flatMap { count in
            let keys = try (1...count).map { try fixed(UInt8($0)) }
            return (1...count).map { ($0, keys) }
        }
        policies += try [(2, [.seed(Data(0..<32)), .seed(Data(32..<64))]),
                         (2, [fixed(6), .seed(Data(64..<96)), .seed(Data(96..<128))])]

        let manyMixed: [BitcoinMultisigKey] = try (0..<15).map { i -> BitcoinMultisigKey in
            if i % 2 == 0 { return try fixed(UInt8(i + 1)) }
            return .seed(Data(repeating: UInt8(150 + i), count: 32))
        }
        let manyHD: [BitcoinMultisigKey] = (0..<15).map { .seed(Data(repeating: UInt8(200 + $0), count: 32)) }
        policies += [(7, manyMixed), (15, manyMixed), (15, manyHD), (1, [try fixed(1), .seed(Data(repeating: 220, count: 32))])]
        var receipts: [[String: Any]] = []
        for (required, keys) in policies {
            let policy = try BitcoinMultisig.wallet(required: required, keys: keys, network: .dogecoin)
            // Multiple receive indices and a change input exercise distinct signing passes.
            let addresses = try policy.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 0..<($0.isHD ? 3 : 1)) }
            let watched = try addresses.map { try BitcoinSendPlan.address($0, on: .regtest, chain: .dogecoin) }
            for address in watched { _ = try await rpc.call("importaddress", [address, "multisig-fixture", false]) }
            let outputs = try Dictionary(uniqueKeysWithValues: addresses.map { (try BitcoinSendPlan.address($0, on: .regtest, chain: .dogecoin), "1.0") })
            let funding = try await rpc.call("sendmany", ["", outputs]) as! String
            _ = try await rpc.call("generate", [1])
            let raw = Data(hex: try await rpc.call("getrawtransaction", [funding]) as! String)!
            let funded = try BitcoinTransactions.details(raw, network: .dogecoin).outputs
            let coins = addresses.map { address in
                BitcoinSendCoin(accountID: "fixture", txid: funding, vout: funded.firstIndex { $0.script == address.script }!,
                    value: 100_000_000, address: address, previousTransaction: raw)
            }
            let changeBranch = policy.branches.last!
            let change = try BitcoinKeys.addresses(branch: changeBranch, range: (changeBranch.isHD ? 7..<8 : 0..<1))[0]
            _ = try await rpc.call("importaddress", [BitcoinSendPlan.address(change, on: .regtest, chain: .dogecoin), "multisig-fixture", false])
            let available = try await rpc.call("listunspent", [1, 9999999, watched]) as! [[String: Any]]
            XCTAssertEqual(available.count, coins.count)
            let recipient = try await rpc.call("getnewaddress", []) as! String
            let plan = try BitcoinSendPlan.make(coins: coins, recipient: recipient, amount: Int64(coins.count) * 100_000_000 - 5_000_000,
                change: change, ratePerKVByte: 1_000_000, network: .regtest, chain: .dogecoin)
            XCTAssertEqual(plan.coins.count, coins.count)
            let signed = try BitcoinMultisig.sign(plan, required: required, keys: keys, network: .dogecoin)
            // Removing a signature must fail even when all remaining signatures are valid.
            let short = try removingFirstSignature(signed.raw)
            // Core 1.14 does not expose testmempoolaccept. Invalid signatures
            // must be rejected by submission before the intact transfer is sent.
            do {
                _ = try await rpc.call("sendrawtransaction", [short.hex])
                XCTFail("Core accepted an insufficient-signature transaction")
            } catch let error as NSError {
                XCTAssertEqual(error.code, -26)
            }
            let hash = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as! String
            XCTAssertEqual(hash, signed.txid)
            _ = try await rpc.call("generate", [1])
            let result = try await rpc.call("getrawtransaction", [hash, 1]) as! [String: Any]
            XCTAssertGreaterThan(result["confirmations"] as! Int, 0)
            XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(plan.maximumVBytes))
            let watchedAfter = Array(Set(watched + [try BitcoinSendPlan.address(change, on: .regtest, chain: .dogecoin)]))
            let remaining = try await rpc.call("listunspent", [1, 9999999, watchedAfter]) as! [[String: Any]]
            let balance = remaining.reduce(Int64(0)) { $0 + NSDecimalNumber(string: String(describing: $1["amount"]!)).multiplying(by: 100_000_000).int64Value }
            XCTAssertEqual(balance, plan.changeAmount)
            let history = try await rpc.call("listtransactions", ["*", 1000, 0, true]) as! [[String: Any]]
            XCTAssertTrue(history.contains { $0["txid"] as? String == funding })
            XCTAssertTrue(history.contains { $0["txid"] as? String == hash })
            let decoded = try BitcoinTransactions.details(signed.raw, network: .dogecoin)
            XCTAssertEqual(Set(decoded.inputs.map(\.txid)), [funding])
            XCTAssertEqual(decoded.outputs.reduce(Int64(0)) { $0 + $1.value } + signed.fee, Int64(coins.count) * 100_000_000)
            receipts.append(["required": required, "keys": keys.count, "txid": hash, "inputs": coins.count,
                             "fee": signed.fee, "balanceAfter": balance, "historyVerified": true,
                             "missingSignatureRejected": true, "confirmations": result["confirmations"] as! Int])
        }
        try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("multisig-receipts.json"))
        print("Dogecoin Core regtest: fixed, HD, mixed, 1-of-2, 2-of-3 and 15-of-15 multisig transactions accepted and mined")
    }
    private func removingFirstSignature(_ raw: Data) throws -> Data {
        // Fixtures have fewer than 253 inputs. First script starts after version,
        // input count and outpoint. Preserve all other transaction bytes.
        let offset = 41
        let prefix = raw[offset] < 253 ? 1 : 3
        let count = prefix == 1 ? Int(raw[offset]) : Int(raw[offset + 1]) + Int(raw[offset + 2]) * 256
        let start = offset + prefix
        var script = Data(raw[start..<(start + count)])
        XCTAssertEqual(script[0], 0)
        let firstLength = Int(script[1])
        XCTAssertEqual(script[1 + firstLength], 0x01)
        script.removeSubrange(1..<(2 + firstLength))
        return Data(raw.prefix(offset)) + BitcoinWire.vector(script) + raw.dropFirst(start + count)
    }
    private func checkSigning(required: Int, keys: [BitcoinMultisigKey], rate: Int64 = 1_000_000) throws {
        let policy = try BitcoinMultisig.wallet(required: required, keys: keys, network: .dogecoin)
        let address = try BitcoinKeys.addresses(branch: policy.branches[0], range: 0..<1)[0]
        let change = try BitcoinKeys.addresses(branch: policy.branches.last!, range: 0..<1)[0]
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(10_000_000_000)) + BitcoinWire.vector(Data(hex: address.script)!) + BitcoinWire.little(UInt32(0))
        let coin = BitcoinSendCoin(accountID: "fixture", txid: try BitcoinTransactions.txid(raw, network: .dogecoin), vout: 0, value: 10_000_000_000,
            address: address, previousTransaction: raw)
        let recipient = try BitcoinKeys.addresses(branch: DogecoinKeys.wallet(seed: Data(64..<96)).branches[0], range: 0..<1)[0]
        let plan = try BitcoinSendPlan.make(coins: [coin], recipient: recipient.address, amount: 5_000_000_000, change: change, ratePerKVByte: rate, chain: .dogecoin)
        let signed = try BitcoinMultisig.sign(plan, required: required, keys: keys, network: .dogecoin)
        XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(plan.maximumVBytes))
        XCTAssertEqual(signed.fee, plan.fee)
        XCTAssertThrowsError(try BitcoinMultisig.sign(plan, required: required, keys: keys, network: .bitcoin))
        let wrongChange = try BitcoinSendPlan.make(coins: [coin], recipient: recipient.address, amount: 5_000_000_000, change: recipient, ratePerKVByte: rate, chain: .dogecoin)
        XCTAssertThrowsError(try BitcoinMultisig.sign(wrongChange, required: required, keys: keys, network: .dogecoin))
        XCTAssertThrowsError(try BitcoinMultisig.sign(plan, required: required == 1 ? 2 : 1, keys: keys, network: .dogecoin))
    }
}

private struct DogecoinMultisigCoreRPC {
    let directory: String
    func call(_ method: String, _ params: [Any]) async throws -> Any {
        let cookie = try String(contentsOfFile: directory + "/regtest/.cookie", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19567")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0", "id":1, "method":method, "params":params])
        let (data, _) = try await URLSession.shared.data(for: request)
        let result = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let error = result["error"] as? [String: Any] {
            throw NSError(domain: "DogecoinMultisigCoreRPC." + method, code: error["code"] as? Int ?? -1)
        }
        return result["result"]!
    }
}
