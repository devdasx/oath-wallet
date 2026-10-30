import XCTest
import OathSecp256k1
@testable import OathBitcoin

final class AezeedBitcoinTests: XCTestCase, @unchecked Sendable {
    // Public upstream aezeed entropy. These fixtures must never hold real money.
    let entropy = Data([0x81,0xb6,0x37,0xd8,0x63,0x59,0xe6,0x96,0x0d,0xe7,0x95,0xe4,0x1e,0x0b,0x4c,0xfd])
    struct Vector: Decodable { let path: String; let address: String; let publicKey: String }
    func testLNDReferenceAddressesAndSigningKeysAcrossAccounts() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "aezeed-lnd-vectors", withExtension: "json"))
        let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
        XCTAssertEqual(vectors.count, 64)
        for account: UInt32 in [0, 1] {
            let wallet = try BitcoinKeys.aezeedWallet(entropy: entropy, account: account)
            XCTAssertEqual(Set(wallet.branches.map(\.id)).count, 8)
            XCTAssertEqual(try JSONDecoder().decode(BitcoinWalletDescriptor.self, from: JSONEncoder().encode(wallet)), wallet)
            for branch in wallet.branches {
                for index: UInt32 in [0,1,19,20] {
                    let address = try BitcoinKeys.addresses(branch: branch, range: index..<(index+1))[0]
                    let reference = try XCTUnwrap(vectors.first { $0.path == address.path })
                    XCTAssertEqual(address.address, reference.address)
                    let wif = try UTXONetwork.bitcoin.privateKeyWIF(source: .aezeed(entropy, account: account), address: address)
                    let decoded = try BitcoinKeys.decodeImport(wif)
                    XCTAssertEqual(try OathSecp256k1.publicKey(decoded.bytes).hex, reference.publicKey)
                }
            }
        }
    }
    func testBIP49PlusDoesNotConfuseChangeWithBIP84() throws {
        let wallet = try BitcoinKeys.aezeedWallet(entropy: entropy)
        let branch = try XCTUnwrap(wallet.branches.first { $0.id == "49:1" })
        XCTAssertEqual(branch.type, .nativeSegwit)
        XCTAssertEqual(branch.path, "m/49'/0'/0'/1")
        let a = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
        XCTAssertThrowsError(try UTXONetwork.bitcoin.privateKeyWIF(source: .seed(entropy, account: 0), address: a))
        XCTAssertThrowsError(try UTXONetwork.litecoin.privateKeyWIF(source: .aezeed(entropy, account: 0), address: a))
        let standard = try BitcoinKeys.wallet(seed: entropy)
        XCTAssertEqual(standard.branches.first { $0.id == "49:1" }?.type, .nestedSegwit)
    }
    func testBalancesAndSpentHistoryFromAllLNDScopes() async throws {
        let wallet = try BitcoinKeys.aezeedWallet(entropy: entropy)
        let query = QueryFixture()
        var replies: [String: BitcoinAddressState] = [:]
        for (i, branch) in wallet.branches.enumerated() {
            let address = try BitcoinKeys.addresses(branch: branch, range: 19..<20)[0]
            let txid = String(repeating: String(i+1), count: 64)
            replies[address.scriptHash] = .init(confirmed: 10_000, unconfirmed: 0,
                history: [.init(txid: txid, height: 100)],
                unspent: [.init(txid: txid, vout: 0, value: 10_000, height: 100)])
        }
        await query.configure(replies)
        let scan = try await BitcoinDiscovery(query: query).scan(wallet)
        try scan.validate(wallet: wallet, requiredThrough: [:])
        XCTAssertEqual(scan.total, 80_000)
        XCTAssertEqual(scan.addresses.count, 320)
        XCTAssertEqual(scan.addresses.filter { !$0.state.history.isEmpty }.count, 8)
        XCTAssertEqual(scan.addresses.first { $0.address.branchID == "49:1" && $0.address.index == 19 }?.state.confirmed, 10_000)
    }
    func testCoreFundedRecoveryAndMixedInputTransfer() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OATH_AEZEED_REGTEST_DIR"] else {
            throw XCTSkip("Isolated local Bitcoin Core integration is opt-in")
        }
        let rpc = AezeedCoreRPC(directory: directory)
        let mining = try await rpc.call("getnewaddress", []) as! String
        _ = try await rpc.call("generatetoaddress", [101, mining])
        let wallet = try BitcoinKeys.aezeedWallet(entropy: entropy)
        let addresses = try wallet.branches.map { try BitcoinKeys.addresses(branch: $0, range: 0..<1)[0] }
        let fundingOutputs = try Dictionary(uniqueKeysWithValues: addresses.map { (try BitcoinSendPlan.address($0, on: .regtest), 0.002) })
        let funding = try await rpc.call("sendmany", ["", fundingOutputs]) as! String
        _ = try await rpc.call("generatetoaddress", [1, mining])
        let rawText = try await rpc.call("getrawtransaction", [funding]) as! String
        let raw = try XCTUnwrap(Data(hex: rawText))
        let outputs = try BitcoinTransactions.details(raw, network: .bitcoin).outputs
        var coins: [BitcoinSendCoin] = []
        let query = QueryFixture()
        var replies: [String: BitcoinAddressState] = [:]
        let height = try await rpc.call("getblockcount", []) as! Int
        for address in addresses {
            let vout = try XCTUnwrap(outputs.firstIndex { $0.script == address.script })
            let output = try await rpc.call("gettxout", [funding, vout]) as! [String: Any]
            XCTAssertEqual((output["value"] as? NSNumber)?.doubleValue, 0.002)
            coins.append(.init(accountID: "aezeed-public-test", txid: funding, vout: vout, value: outputs[vout].value,
                               address: address, previousTransaction: raw))
            replies[address.scriptHash] = .init(confirmed: outputs[vout].value, unconfirmed: 0,
                history: [.init(txid: funding, height: Int64(height))],
                unspent: [.init(txid: funding, vout: vout, value: outputs[vout].value, height: Int64(height))])
        }
        await query.configure(replies)
        let recovered = try await BitcoinDiscovery(query: query).scan(wallet)
        try recovered.validate(wallet: wallet, requiredThrough: [:])
        XCTAssertEqual(recovered.total, 1_600_000)
        let change = try BitcoinKeys.addresses(branch: wallet.branches.first { $0.id == "49:1" }!, range: 1..<2)[0]
        let destination = try await rpc.call("getnewaddress", []) as! String
        let plan = try BitcoinSendPlan.make(coins: coins, recipient: destination, amount: 1_500_000,
                                            change: change, ratePerKVByte: 2000, network: .regtest)
        XCTAssertEqual(plan.coins.count, 8)
        let signed = try BitcoinSendSigner.sign(plan) { _ in .aezeed(self.entropy, account: 0) }
        let acceptance = try await rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
        XCTAssertEqual(acceptance[0]["allowed"] as? Bool, true)
        let broadcast = try await rpc.call("sendrawtransaction", [signed.raw.hex]) as! String
        XCTAssertEqual(broadcast, signed.txid)
        _ = try await rpc.call("generatetoaddress", [1, mining])
        let confirmed = try await rpc.call("getrawtransaction", [signed.txid, true]) as! [String: Any]
        XCTAssertGreaterThan(confirmed["confirmations"] as! Int, 0)
        for coin in coins { let spent = try await rpc.call("gettxout", [coin.txid, coin.vout]); XCTAssertTrue(spent is NSNull) }
        let sent = try BitcoinTransactions.details(signed.raw, network: .bitcoin)
        let changeIndex = try XCTUnwrap(sent.outputs.firstIndex { $0.script == change.script })
        let changeOutput = try await rpc.call("gettxout", [signed.txid, changeIndex]) as! [String: Any]
        let sats = ((changeOutput["value"] as! NSNumber).decimalValue * 100_000_000)
        XCTAssertEqual(NSDecimalNumber(decimal: sats).int64Value, plan.changeAmount)
        XCTAssertEqual(plan.changeAmount, recovered.total - plan.recipientAmount - plan.fee)
    }
}
private struct AezeedCoreRPC {
    let directory: String
    func call(_ method: String, _ params: [Any]) async throws -> Any {
        let cookie = try String(contentsOfFile: directory + "/regtest/.cookie", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:19643/wallet/aezeed-test")!)
        request.httpMethod = "POST"; request.timeoutInterval = 30
        request.setValue("Basic " + Data(cookie.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["jsonrpc":"2.0","id":1,"method":method,"params":params])
        let (data, _) = try await URLSession.shared.data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        if let failure = object["error"] as? [String: Any] { throw NSError(domain: "AezeedCoreRPC.\(method)", code: failure["code"] as? Int ?? -1) }
        return object["result"]!
    }
}
