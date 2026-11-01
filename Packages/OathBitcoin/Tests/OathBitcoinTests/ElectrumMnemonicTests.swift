import XCTest
import OathSecp256k1
@testable import OathBitcoin

final class ElectrumMnemonicTests: XCTestCase, @unchecked Sendable {
    struct Vector: Decodable {
        let name: String, phrase: String, password: String, kind: String, normalized: String
        struct Address: Decodable { let change: UInt32, index: UInt32; let address: String; let publicKeys: [String] }
        let addresses: [Address]
    }
    func vectors() throws -> [Vector] {
        try JSONDecoder().decode([Vector].self, from: Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: "electrum-reference", withExtension: "json"))))
    }
    func testFinalNormalChildElectrumLeafExport() throws {
        let vector = try XCTUnwrap(vectors().first { $0.kind == "segwit" })
        let material = try ElectrumMnemonic.decode(vector.phrase, passphrase: vector.password)
        let branch = try XCTUnwrap(ElectrumBitcoin.wallet(material).branches.first)
        let address = try XCTUnwrap(BitcoinKeys.addresses(branch: branch, range: 0x7fff_ffff..<0x8000_0000).first)
        let key = try BitcoinKeys.decodeImport(ElectrumBitcoin.privateKey(material, address: address))
        let single = try XCTUnwrap(BitcoinKeys.singleKey(bytes: key.bytes, compressed: key.compressed).branches.first { $0.type == address.type })
        XCTAssertEqual(try BitcoinKeys.addresses(branch: single, range: 0..<1).first?.script, address.script)
    }

    func testUpstreamAddressesAndPrivateKeys() throws {
        let vectors = try vectors()
        XCTAssertGreaterThan(vectors.count, 15)
        for vector in vectors {
            XCTAssertEqual(ElectrumMnemonic.normalize(vector.phrase), vector.normalized, vector.name)
            let material = try ElectrumMnemonic.decode(vector.phrase, passphrase: vector.password)
            let kind = material.kind == .twoFactor ? "2fa" : material.kind == .twoFactorSegwit ? "2fa_segwit" : material.kind.rawValue
            XCTAssertEqual(kind, vector.kind, vector.name)
            let wallet = try ElectrumBitcoin.wallet(material)
            XCTAssertEqual(wallet.branches.count, 2)
            XCTAssertEqual(try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: JSONEncoder().encode(wallet)), wallet)
            for expected in vector.addresses {
                let branch = try XCTUnwrap(wallet.branches.first { $0.change == expected.change })
                let actual = try BitcoinKeys.addresses(branch: branch, range: expected.index..<(expected.index+1))[0]
                XCTAssertEqual(actual.address, expected.address, "\(vector.name):\(expected.change)/\(expected.index)")
                if !material.kind.isTwoFactor {
                    let key = try BitcoinKeys.decodeImport(ElectrumBitcoin.privateKey(material, address: actual))
                    XCTAssertEqual(try OathSecp256k1.publicKey(key.bytes, compressed: key.compressed).hex, expected.publicKeys[0], vector.name)
                } else { XCTAssertNotNil(actual.multisigInputWeight) }
            }
        }
    }
    func testExtensionsNormalizationAndIsolation() throws {
        let vectors = try vectors()
        let standard = try XCTUnwrap(vectors.first { $0.kind == "standard" && $0.password.isEmpty })
        let a = try ElectrumMnemonic.decode(standard.phrase)
        let b = try ElectrumMnemonic.decode(standard.phrase.uppercased().replacingOccurrences(of: " ", with: " \n "))
        XCTAssertEqual(a,b)
        XCTAssertNotEqual(try ElectrumBitcoin.wallet(a), try ElectrumBitcoin.wallet(ElectrumMnemonic.decode(standard.phrase, passphrase: "another")))
        XCTAssertNotEqual(try ElectrumBitcoin.wallet(a), try BitcoinKeys.wallet(seed: a.seed))
        let legacy = try XCTUnwrap(vectors.first { $0.kind == "old" })
        XCTAssertThrowsError(try ElectrumMnemonic.decode(legacy.phrase, passphrase: "extension"))
        XCTAssertThrowsError(try OathSecp256k1.adding(Data(repeating: 0, count: 32), toPublicKey: Data()))
        XCTAssertNil(ElectrumMnemonic.kind(""))
        XCTAssertNil(ElectrumMnemonic.kind(String(repeating: "a", count: 4097)))
        let wallet = try ElectrumBitcoin.wallet(a)
        let address = try BitcoinKeys.addresses(branch: wallet.branches[0], range: 0..<1)[0]
        XCTAssertThrowsError(try UTXONetwork.litecoin.privateKeyWIF(source: .electrum(a), address: address))
    }
    func testDiscoveryKeepsReceiveChangeAndSpentHistory() async throws {
        for vector in try vectors().filter({ $0.password.isEmpty }).prefix(7) {
            let wallet = try ElectrumBitcoin.wallet(ElectrumMnemonic.decode(vector.phrase))
            let query = QueryFixture()
            var states: [String: BitcoinAddressState] = [:]
            for (n, branch) in wallet.branches.enumerated() {
                let address = try BitcoinKeys.addresses(branch: branch, range: 19..<20)[0]
                let txid = String(repeating: n == 0 ? "a" : "b", count: 64)
                states[address.scriptHash] = .init(confirmed: n == 0 ? 123456 : 0, unconfirmed: 0,
                    history: [.init(txid: txid, height: 12)], unspent: n == 0 ? [.init(txid: txid, vout: 0, value: 123456, height: 12)] : [])
            }
            await query.configure(states)
            let scan = try await BitcoinDiscovery(query: query).scan(wallet)
            try scan.validate(wallet: wallet, requiredThrough: [:])
            XCTAssertEqual(scan.total, 123456)
            XCTAssertEqual(scan.addresses.filter { !$0.state.history.isEmpty }.count, 2)
            XCTAssertEqual(scan.addresses.count, 80)
        }
    }

    func testCoreFundedRecoveryAndTransfersForEverySeedType() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_ELECTRUM_REGTEST_DIR"] else {
            throw XCTSkip("Isolated local Bitcoin Core integration is opt-in")
        }
        let rpc = ElectrumCoreRPC(directory: directory)
        let mining = try await rpc.call("getnewaddress", []) as! String
        _ = try await rpc.call("generatetoaddress", [101, mining])
        var kinds = Set<String>()
        var tested = 0
        for vector in try vectors() where vector.name.hasPrefix("test_electrum_seed_") {
            kinds.insert(vector.kind); tested += 1
            let material = try ElectrumMnemonic.decode(vector.phrase, passphrase: vector.password)
            let wallet = try ElectrumBitcoin.wallet(material)
            let addresses = try wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
            let outputs = try Dictionary(uniqueKeysWithValues: addresses.map { (try BitcoinSendPlan.address($0, on: .regtest), 0.002) })
            let txid = try await rpc.call("sendmany", ["", outputs]) as! String
            _ = try await rpc.call("generatetoaddress", [1, mining])
            let rawText = try await rpc.call("getrawtransaction", [txid]) as! String
            let raw = try XCTUnwrap(Data(hex: rawText))
            let details = try BitcoinTransactions.details(raw, network: .bitcoin)
            let height = try await rpc.call("getblockcount", []) as! Int
            var states: [String: BitcoinAddressState] = [:]
            var coins: [BitcoinSendCoin] = []
            for address in addresses {
                let index = try XCTUnwrap(details.outputs.firstIndex { $0.script == address.script })
                let output = try await rpc.call("gettxout", [txid, index]) as! [String: Any]
                XCTAssertEqual((output["value"] as! NSNumber).doubleValue, 0.002)
                let amount = details.outputs[index].value
                states[address.scriptHash] = .init(confirmed: amount, unconfirmed: 0, history: [.init(txid: txid, height: Int64(height))], unspent: [.init(txid: txid, vout: index, value: amount, height: Int64(height))])
                coins.append(.init(accountID: "electrum-test", txid: txid, vout: index, value: amount,
                    address: address, previousTransaction: raw, compressed: material.kind != .old))
            }
            let query = QueryFixture(); await query.configure(states)
            let scan = try await BitcoinDiscovery(query: query).scan(wallet)
            XCTAssertEqual(scan.total, 400_000)
            let change = try BitcoinKeys.addresses(branch: wallet.branches[1], range: 1..<2)[0]
            let recipient = try await rpc.call("getnewaddress", []) as! String
            let plan = try BitcoinSendPlan.make(coins: coins, recipient: recipient, amount: 350_000, change: change,
                ratePerKVByte: 2000, network: .regtest)
            XCTAssertEqual(plan.coins.count, 2)
            let other = try ElectrumMnemonic.decode(try XCTUnwrap(vectors().first { $0.kind == "standard" }).phrase, passphrase: "unrelated")
            XCTAssertThrowsError(try ElectrumBitcoin.sign(plan, material: other))
            let alienChange = try BitcoinKeys.addresses(branch: ElectrumBitcoin.wallet(other).branches[1], range: 0..<1)[0]
            let redirected = try BitcoinSendPlan.make(coins: coins, recipient: recipient, amount: 350_000,
                change: alienChange, ratePerKVByte: 2000, network: .regtest)
            XCTAssertThrowsError(try ElectrumBitcoin.sign(redirected, material: material))
            let signed = try ElectrumBitcoin.sign(plan, material: material)
            let accepted = try await rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
            XCTAssertEqual(accepted[0]["allowed"] as? Bool, true, vector.kind)
            let broadcast = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as? String
            XCTAssertEqual(broadcast, signed.txid)
            _ = try await rpc.call("generatetoaddress", [1, mining])
            let confirmed = try await rpc.call("getrawtransaction", [signed.txid, true]) as! [String: Any]
            XCTAssertGreaterThan(confirmed["confirmations"] as! Int, 0)
            for coin in coins { let output = try await rpc.call("gettxout", [coin.txid, coin.vout]); XCTAssertTrue(output is NSNull) }
            let sent = try BitcoinTransactions.details(signed.raw, network: .bitcoin)
            let changeIndex = try XCTUnwrap(sent.outputs.firstIndex { $0.script == change.script })
            let remaining = try await rpc.call("gettxout", [signed.txid, changeIndex]) as! [String: Any]
            let actual = NSDecimalNumber(decimal: (remaining["value"] as! NSNumber).decimalValue * 100_000_000).int64Value
            XCTAssertEqual(actual, plan.changeAmount)
            XCTAssertEqual(actual, 400_000 - plan.recipientAmount - plan.fee)
            print("Bitcoin Core verified Electrum \(vector.kind): recovered 400000 sat, signed, accepted, mined, spent inputs and change reconciled.")
        }
        XCTAssertEqual(kinds.count, 5)
        XCTAssertEqual(tested, 11)
    }
}
private struct ElectrumCoreRPC {
    let directory: String
    func call(_ method: String, _ params: [Any]) async throws -> Any {
        let cookie = try String(contentsOfFile: directory + "/regtest/.cookie", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19653/wallet/electrum-test")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":1,"method":method,"params":params])
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let failure = object["error"] as? [String: Any] { throw NSError(domain: "ElectrumCoreRPC.\(method)", code: failure["code"] as? Int ?? -1) }
        return object["result"]!
    }
}
