import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinSendTests: XCTestCase {
    // Published, deterministic test material. Never used on mainnet.
    let seed = Data(0..<32)
    func address(_ type: BitcoinAddressType = .nativeSegwit, change: UInt32 = 0, index: UInt32 = 0) throws -> BitcoinDerivedAddress {
        let branch = try BitcoinKeys.wallet(seed: seed).branches.first { $0.type == type && $0.change == change }!
        return try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
    }
    func coin(_ value: Int64, type: BitcoinAddressType = .nativeSegwit, index: UInt32 = 0,
              change: UInt32 = 0, compressed: Bool = true) throws -> BitcoinSendCoin {
        let a = try compressed ? address(type, change: change, index: index) : BitcoinKeys.addresses(
            branch: BitcoinKeys.singleKey(bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false).branches[0], range: 0..<1)[0]
        // Synthetic funding transaction for pure signing tests; Core tests below
        // use real mined/funded transactions instead.
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(index) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(value)) + BitcoinWire.vector(Data(hex: a.script)!)
        raw += BitcoinWire.little(UInt32(0))
        return .init(accountID: "test", txid: try BitcoinTransactions.txid(raw), vout: 0, value: value,
                     address: a, previousTransaction: raw, compressed: compressed)
    }
    func plan(_ coins: [BitcoinSendCoin], amount: Int64, rate: Int64 = 2000) throws -> BitcoinSendPlan {
        try .make(coins: coins, recipient: address(.taproot, index: 12).address, amount: amount,
                  change: address(change: 1), ratePerKVByte: rate)
    }

    func testFinalNormalChildSignsInputAndChange() throws {
        let index: UInt32 = 0x7fff_ffff
        let plan = try BitcoinSendPlan.make(coins: [coin(100_000, index: index)], recipient: address(index: 1).address,
                                            amount: 50_000, change: address(change: 1, index: index), ratePerKVByte: 2000)
        let signed = try BitcoinSendSigner.sign(plan) { _ in .seed(self.seed, account: 0) }
        XCTAssertEqual(try BitcoinTransactions.txid(signed.raw), signed.txid)
        XCTAssertEqual(signed.fee, plan.fee)
    }

    func testMixedTypesBothPathsAndAllRecipientsSign() throws {
        for target in BitcoinAddressType.allCases {
            let coins = try BitcoinAddressType.allCases.enumerated().flatMap { offset, type in
                try [coin(20_000, type: type, index: UInt32(offset)), coin(20_000, type: type, index: UInt32(offset + 4), change: 1)]
            }
            let plan = try BitcoinSendPlan.make(coins: coins, recipient: address(target, index: 15).address,
                                               amount: 155_000, change: address(change: 1), ratePerKVByte: 2000)
            XCTAssertEqual(plan.coins.count, 8)
            let signed = try BitcoinSendSigner.sign(plan) { _ in .seed(self.seed, account: 0) }
            XCTAssertEqual(try BitcoinTransactions.txid(signed.raw), signed.txid)
            XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(plan.maximumVBytes))
        }
    }
    func testFeeUsesRemainderBeforeRecipient() throws {
        let p = try plan([coin(100_000)], amount: 60_000)
        XCTAssertEqual(p.recipientAmount, 60_000); XCTAssertEqual(p.deductedFromAmount, 0)
        XCTAssertEqual(p.remainingBalance, 100_000 - 60_000 - p.fee)
        XCTAssertGreaterThan(p.changeAmount, 294)
    }
    func testSweepAndInsufficientRemainderDeductOnlyRequiredFee() throws {
        for amount in [100_000, 99_999] as [Int64] {
            let p = try plan([coin(100_000)], amount: amount)
            XCTAssertEqual(p.changeAmount, 0); XCTAssertEqual(p.total, 100_000)
            XCTAssertEqual(p.recipientAmount, 100_000 - p.fee)
            XCTAssertEqual(p.deductedFromAmount, amount - p.recipientAmount)
        }
    }
    func testTinyUnspentWalletRemainderIsAllowed() throws {
        let p = try plan([coin(100_000), coin(100, index: 1)], amount: 99_720, rate: 1000)
        XCTAssertEqual(p.coins.count, 1); XCTAssertEqual(p.changeAmount, 0)
        XCTAssertEqual(p.remainingBalance, 100)
    }
    func testDustChangeFoldedIntoFeeAndDustRecipientRejected() throws {
        let p = try plan([coin(100_000)], amount: 99_700, rate: 1000)
        XCTAssertEqual(p.changeAmount, 0); XCTAssertEqual(p.fee, 300)
        XCTAssertThrowsError(try plan([coin(100_000)], amount: 100))
    }
    func testExactMatchingCoinAvoidsUnnecessaryInputs() throws {
        let p = try plan([coin(40_000), coin(100_000, index: 1), coin(60_000, index: 2)], amount: 80_000)
        XCTAssertEqual(p.coins.count, 1); XCTAssertEqual(p.coins[0].value, 100_000)
    }
    func testAmountFeeAndDustInvariantsAcrossVaryingPools() throws {
        let coins = try (0..<8).map { try coin(Int64(10_000 + $0 * 7_000), type: BitcoinAddressType.allCases[$0 % 4], index: UInt32($0)) }
        let balance = coins.reduce(Int64(0)) { $0 + $1.value }
        for rate: Int64 in [1_000, 1_500, 10_000, 50_000] {
            for numerator: Int64 in 1...12 {
                let amount = balance * numerator / 12
                let p = try plan(coins, amount: amount, rate: rate)
                try p.validate()
                XCTAssertEqual(p.coins.reduce(0) { $0 + $1.value }, p.recipientAmount + p.changeAmount + p.fee)
                XCTAssertEqual(p.remainingBalance, balance - p.recipientAmount - p.fee)
                XCTAssertGreaterThanOrEqual(p.remainingBalance, 0)
                XCTAssertLessThanOrEqual(p.recipientAmount, amount)
                XCTAssertTrue(p.changeAmount == 0 || p.changeAmount >= 294)
            }
        }
    }
    func testTamperedReviewCannotSign() throws {
        let p = try plan([coin(100_000)], amount: 50_000)
        for key in ["fee", "recipientAmount", "changeAmount", "maximumVBytes", "walletBalance"] {
            var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
            value[key] = key == "walletBalance" ? 50_000 : Int64.max
            let tampered = try JSONDecoder().decode(BitcoinSendPlan.self, from: JSONSerialization.data(withJSONObject: value))
            XCTAssertThrowsError(try BitcoinSendSigner.sign(tampered) { _ in .seed(self.seed, account: 0) })
        }
    }

    func testLiveMainnetFeeQuoteIsReadOnly() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_LIVE_FEE"] == "1" else { throw XCTSkip("Live public fee lookup is opt-in") }
        let pool = ElectrumPool(network: .bitcoin)
        let rate = try await pool.bitcoinFeeRate()
        XCTAssertTrue((1_000...1_000_000).contains(rate))
        await pool.close()
        print("Live Bitcoin mainnet fee lookup passed; no transaction submitted")
    }
    func testFeeProviderFallbackAndRelayMinimum() async throws {
        let pool = ElectrumPool(servers: [.init("unavailable"), .init("ready")], maximumConnections: 1) {
            StubTransport($0.host == "unavailable" ? .fee(.integer(-1), .decimal(0.00001)) : .fee(.decimal(0.000012345), .decimal(0.00002)))
        }
        let rate = try await pool.bitcoinFeeRate()
        XCTAssertEqual(rate, 2000)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.count, 2)
        await pool.close()
    }
    func testBroadcastRequiresMatchingLocallyComputedTransactionID() async throws {
        let p = try plan([coin(100_000)], amount: 50_000)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
        let pool = ElectrumPool(servers: [.init("wrong"), .init("matching")], maximumConnections: 1) {
            StubTransport(.broadcast($0.host == "wrong" ? String(repeating: "0", count: 64) : signed.txid))
        }
        let returned = try await pool.broadcastBitcoin(signed.raw)
        XCTAssertEqual(returned, signed.txid)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.map(\.error), [.invalidResponse, nil])
        await pool.close()
    }
    func testDuplicateForgedAndWrongNetworkRejected() throws {
        let c = try coin(100_000)
        XCTAssertThrowsError(try plan([c,c], amount: 50_000))
        let forged = BitcoinSendCoin(accountID: c.accountID, txid: c.txid, vout: 0, value: 200_000,
                                     address: c.address, previousTransaction: c.previousTransaction)
        XCTAssertThrowsError(try plan([forged], amount: 50_000))
        XCTAssertThrowsError(try BitcoinSendPlan.make(coins: [c], recipient: BitcoinSendPlan.address(address(), on: .regtest),
                                                    amount: 50_000, change: address(change: 1), ratePerKVByte: 1000))
        XCTAssertThrowsError(try plan([c], amount: 100_001))
        XCTAssertThrowsError(try plan([c], amount: 0))
        XCTAssertThrowsError(try plan([c], amount: 50_000, rate: 0))
    }
    func testExpiredAndWrongKeyRejected() throws {
        let p = try plan([coin(100_000)], amount: 50_000)
        XCTAssertThrowsError(try p.validate(now: p.createdAt.addingTimeInterval(121)))
        XCTAssertThrowsError(try BitcoinSendSigner.sign(p) { _ in .seed(Data(1...32), account: 0) })
    }
    func testUncompressedImportedLegacyKey() throws {
        let p = try plan([coin(100_000, type: .legacy, compressed: false)], amount: 50_000)
        let tx = try BitcoinSendSigner.sign(p) { _ in .single(Data(repeating: 0, count: 31) + Data([1]), compressed: false) }
        XCTAssertLessThanOrEqual(tx.virtualBytes, UInt64(p.maximumVBytes))
    }
    func testManyInputsAndCompactSizeBoundary() throws {
        let coins = try (0..<255).map { try coin(2000, type: BitcoinAddressType.allCases[$0 % 4], index: UInt32($0)) }
        let p = try plan(coins, amount: 510_000, rate: 1000)
        XCTAssertEqual(p.coins.count, 255)
        let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
        XCTAssertLessThanOrEqual(signed.virtualBytes, UInt64(p.maximumVBytes))
    }

    func testBitcoinCoreMixedPoolSweepsDustAndImportedKey() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_BITCOIN_REGTEST_DIR"] else {
            throw XCTSkip("Bitcoin Core integration is opt-in")
        }
        let rpc = CoreRPC(directory: directory)
        let mining = try await rpc.call("getnewaddress", []) as! String
        _ = try await rpc.call("generatetoaddress", [101, mining])
        let mixed = try (0..<255).map {
            try address(BitcoinAddressType.allCases[$0 % 4], change: UInt32(($0 / 4) % 2), index: UInt32(1_000 + $0))
        }
        let uncompressed = try BitcoinKeys.addresses(branch: BitcoinKeys.singleKey(
            bytes: Data(repeating: 0, count: 31) + Data([1]), compressed: false).branches[0], range: 0..<1)[0]
        // Many inputs cross CompactSize's 252 boundary. The smaller cases
        // exercise fee-from-remainder, partial deduction, dust change, and WIF.
        let scenarios: [([BitcoinDerivedAddress], Int64, Int64)] = [
            (mixed, 2_000, 510_000),
            ([try address(index: 2_000)], 100_000, 99_999),
            ([try address(index: 2_001)], 100_000, 99_700),
            ([uncompressed], 100_000, 50_000)
        ]
        for (index, scenario) in scenarios.enumerated() {
            let (addresses, value, requested) = scenario
            let fundingOutputs = try Dictionary(uniqueKeysWithValues: addresses.map {
                (try BitcoinSendPlan.address($0, on: .regtest), NSDecimalNumber(decimal: Decimal(value) / 100_000_000).stringValue)
            })
            let hash = try await rpc.call("sendmany", ["", fundingOutputs, 1, "", [], true, NSNull(), "unset", 2]) as! String
            _ = try await rpc.call("generatetoaddress", [1, mining])
            let raw = Data(hex: try await rpc.call("getrawtransaction", [hash]) as! String)!
            let outputs = try BitcoinTransactions.details(raw, network: .bitcoin).outputs
            let coins = addresses.map { a in
                BitcoinSendCoin(accountID: "test", txid: hash, vout: outputs.firstIndex { $0.script == a.script }!,
                                value: value, address: a, previousTransaction: raw, compressed: index != 3)
            }
            let p = try BitcoinSendPlan.make(coins: coins, recipient: BitcoinSendPlan.address(address(.taproot, index: 3_000), on: .regtest),
                amount: requested, change: address(change: 1, index: UInt32(3_000 + index)), ratePerKVByte: 1000, network: .regtest)
            let signed = try BitcoinSendSigner.sign(p) { _ in
                index == 3 ? .single(Data(repeating: 0, count: 31) + Data([1]), compressed: false) : .seed(self.seed, account: 0)
            }
            XCTAssertEqual(p.coins.count, addresses.count)
            let check = try await rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
            XCTAssertEqual(check[0]["allowed"] as? Bool, true)
            let first = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as? String
            let again = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as? String
            XCTAssertEqual(first, signed.txid); XCTAssertEqual(again, signed.txid)
            _ = try await rpc.call("generatetoaddress", [1, mining])
            let receipt = try await rpc.call("getrawtransaction", [signed.txid, true]) as! [String: Any]
            XCTAssertGreaterThan(receipt["confirmations"] as! Int, 0)
        }
        print("Bitcoin Core: mixed 255-input sweep, insufficient remainder, dust change and uncompressed import accepted and mined; identical rebroadcasts are idempotent")
    }

    func testPublicTestnet4RoundTrip() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_BITCOIN_TESTNET_DIR"] else {
            throw XCTSkip("Public testnet4 is opt-in and uses a fresh, isolated test wallet")
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("test-seed.bin")
        if !FileManager.default.fileExists(atPath: file.path) {
            let random = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            try random.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        var testSeed = try Data(contentsOf: file)
        defer { testSeed.resetBytes(in: 0..<testSeed.count) }
        let descriptor = try BitcoinKeys.wallet(seed: testSeed)
        func derived(_ type: BitcoinAddressType, _ change: UInt32, _ index: UInt32) throws -> BitcoinDerivedAddress {
            let branch = descriptor.branches.first { $0.type == type && $0.change == change }!
            return try BitcoinKeys.addresses(branch: branch, range: index..<(index+1))[0]
        }
        let initial = try derived(.nativeSegwit, 0, 0)
        let receive = try BitcoinSendPlan.address(initial, on: .testnet4)
        print("Public testnet4 funding address: " + receive)
        try receive.write(to: root.appendingPathComponent("address.txt"), atomically: true, encoding: .utf8)
        let api = URL(string: "https://mempool.space/testnet4/api/")!
        func get(_ path: String) async throws -> Data {
            let (data,response) = try await URLSession.shared.data(from: api.appendingPathComponent(path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BitcoinError.unavailable }
            return data
        }
        let outputs = try JSONSerialization.jsonObject(with: await get("address/" + receive + "/utxo")) as! [[String: Any]]
        guard !outputs.isEmpty else { throw XCTSkip("Fresh public testnet4 address awaits faucet funding: " + receive) }
        var coins: [BitcoinSendCoin] = []
        for output in outputs {
            let txid = output["txid"] as! String
            let raw = Data(hex: String(data: try await get("tx/" + txid + "/hex"), encoding: .utf8)!)!
            coins.append(.init(accountID: "public-test", txid: txid, vout: output["vout"] as! Int,
                               value: output["value"] as! Int64, address: initial, previousTransaction: raw))
        }
        let fees = try JSONSerialization.jsonObject(with: await get("v1/fees/recommended")) as! [String: Any]
        let rate = Int64(max(1, min(50, fees["halfHourFee"] as? Int ?? 2))) * 1000
        var receipts: [[String: Any]] = []
        // Move test coins through every output type. Full sweeps exercise fee
        // deduction with actual relay acceptance and locally computed txids.
        // The last native-SegWit destination also spends the legacy output,
        // ensuring that all four input signing algorithms reach the network.
        for (index,type) in (BitcoinAddressType.allCases + [.nativeSegwit]).enumerated() {
            let target = try derived(type, 0, UInt32(index + 1))
            let amount = coins.reduce(Int64(0)) { $0 + $1.value }
            let plan = try BitcoinSendPlan.make(coins: coins, recipient: BitcoinSendPlan.address(target, on: .testnet4),
                amount: amount, change: derived(.nativeSegwit, 1, UInt32(index)), ratePerKVByte: rate, network: .testnet4)
            let signed = try BitcoinSendSigner.sign(plan) { _ in .seed(testSeed, account: 0) }
            var request = URLRequest(url: api.appendingPathComponent("tx")); request.httpMethod = "POST"
            request.setValue("text/plain", forHTTPHeaderField: "Content-Type"); request.httpBody = Data(signed.raw.hex.utf8)
            let (data,response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BitcoinSendError.submissionUnknown }
            XCTAssertEqual(String(data: data, encoding: .utf8), signed.txid)
            let returned = try await get("tx/" + signed.txid + "/hex")
            XCTAssertEqual(Data(hex: String(data: returned, encoding: .utf8)!), signed.raw)
            receipts.append(["txid":signed.txid,"type":type.rawValue,"fee":plan.fee,"vbytes":signed.virtualBytes])
            try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("receipts.json"))
            coins = [.init(accountID: "public-test", txid: signed.txid, vout: 0, value: plan.recipientAmount, address: target, previousTransaction: signed.raw)]
        }
        XCTAssertEqual(receipts.count,5)
        print("Public testnet4: five real signed transactions relayed and fetched back byte-for-byte")
    }

    func testBitcoinCoreAcceptsAndMinesRealTypeMatrix() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_BITCOIN_REGTEST_DIR"] else {
            throw XCTSkip("Set OATH_BITCOIN_REGTEST_DIR to run the isolated Bitcoin Core integration matrix")
        }
        let rpc = CoreRPC(directory: directory)
        _ = try? await rpc.call("createwallet", ["oath-send"])
        let mining = try await rpc.call("getnewaddress", []) as! String
        _ = try await rpc.call("generatetoaddress", [101, mining])
        var accepted = 0
        for sourceType in BitcoinAddressType.allCases {
            for destinationType in BitcoinAddressType.allCases {
                for changePath: UInt32 in [0,1] {
                    let a = try address(sourceType, change: changePath, index: UInt32(accepted + 50))
                    let destination = try BitcoinSendPlan.address(address(destinationType, index: 100), on: .regtest)
                    let funding = try await rpc.call("sendtoaddress", [BitcoinSendPlan.address(a, on: .regtest), 0.002, "", "", false, true, NSNull(), "unset", NSNull(), 2]) as! String
                    _ = try await rpc.call("generatetoaddress", [1,mining])
                    let raw = Data(hex: try await rpc.call("getrawtransaction", [funding]) as! String)!
                    let outputs = try BitcoinTransactions.details(raw, network: .bitcoin).outputs
                    let vout = outputs.firstIndex { $0.script == a.script }!
                    let c = BitcoinSendCoin(accountID: "test", txid: funding, vout: vout, value: outputs[vout].value,
                                            address: a, previousTransaction: raw)
                    let p = try BitcoinSendPlan.make(coins: [c], recipient: destination, amount: 100_000,
                                                    change: address(change: 1, index: UInt32(200 + accepted)), ratePerKVByte: 2000, network: .regtest)
                    let signed = try BitcoinSendSigner.sign(p) { _ in .seed(self.seed, account: 0) }
                    let check = try await rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
                    XCTAssertEqual(check[0]["allowed"] as? Bool, true, "Core rejected \(sourceType) → \(destinationType): \(check[0]["reject-reason"] ?? "unknown")")
                    let broadcast = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as! String
                    XCTAssertEqual(broadcast, signed.txid)
                    _ = try await rpc.call("generatetoaddress", [1,mining])
                    let receipt = try await rpc.call("getrawtransaction", [signed.txid, true]) as! [String: Any]
                    XCTAssertGreaterThan(receipt["confirmations"] as! Int, 0)
                    accepted += 1
                }
            }
        }
        XCTAssertEqual(accepted, 32)
        print("Bitcoin Core: 32 source/destination/receive/change combinations accepted, broadcast and mined")
    }
}

private struct CoreRPC {
    let directory: String
    func call(_ method: String, _ params: [Any]) async throws -> Any {
        let cookie = try String(contentsOfFile: directory + "/regtest/.cookie", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19543/wallet/oath-send")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":1,"method":method,"params":params])
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let failure = object["error"] as? [String: Any] {
            // Only method + numerical code: never dump RPC arguments/credentials.
            throw NSError(domain: "CoreRPC.\(method)", code: failure["code"] as? Int ?? -1)
        }
        return object["result"]!
    }
}
