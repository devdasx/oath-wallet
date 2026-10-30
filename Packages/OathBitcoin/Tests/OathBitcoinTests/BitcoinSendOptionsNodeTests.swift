import Foundation
import XCTest
@testable import OathBitcoin

/// Opt-in, isolated regtest nodes with standardness enforcement. No mainnet or
/// public testnet is contacted and all keys are public deterministic fixtures.
final class BitcoinSendOptionsNodeTests: XCTestCase {
    func testNodesAcceptMessagesAndEnforceRBF() throws {
        guard ProcessInfo.processInfo.environment["OATH_OPTIONS_REGTEST"] == "1" else {
            throw XCTSkip("Run the isolated node harness described in Design/SendOptionsValidation.md")
        }
        let seed = Data(0..<32)
        var accepted = 0
        for chain in UTXONetwork.allCases {
            let rpc = OptionsNodeRPC(chain: chain)
            if chain != .dogecoin {
                let wallet = rpc.wallet
                let loaded = try rpc.call("listwallets", []) as! [String]
                if !loaded.contains(wallet) {
                    let directory = try rpc.call("listwalletdir", []) as! [String: Any]
                    if (directory["wallets"] as! [[String: Any]]).contains(where: { $0["name"] as? String == wallet }) {
                        _ = try rpc.call("loadwallet", [wallet])
                    } else { _ = try rpc.call("createwallet", [wallet]) }
                }
            }
            let mining = try rpc.call("getnewaddress", []) as! String
            func mine(_ count: Int) throws {
                if chain == .dogecoin { _ = try rpc.call("generate", [count]) }
                else { _ = try rpc.call("generatetoaddress", [count, mining]) }
            }
            try mine(chain == .dogecoin ? 241 : 101)
            let descriptor = try chain.wallet(seed: seed)
            let types: [BitcoinAddressType] = chain == .bitcoin || chain == .litecoin ? BitcoinAddressType.allCases : [.legacy]
            for type in types {
                for branch: UInt32 in [0,1] {
                    for rbf in BitcoinSendOptions.supportsRBF(chain) ? [false,true] : [false] {
                        let b = descriptor.branches.first { $0.type == type && $0.change == branch }!
                        let a = try BitcoinKeys.addresses(branch: b, range: 200..<201)[0]
                        let change = try BitcoinKeys.addresses(branch: descriptor.branches.first { $0.type == type && $0.change == 1 }!, range: 201..<202)[0]
                        let destination = try BitcoinSendPlan.address(a, on: .regtest, chain: chain)
                        let hash = try rpc.call("sendtoaddress", [destination, 1]) as! String
                        try mine(1)
                        let parent = Data(hex: try rpc.call("getrawtransaction", [hash]) as! String)!
                        let funding = try BitcoinTransactions.details(parent, network: chain)
                        let index = funding.outputs.firstIndex { $0.script == a.script }!
                        let coin = BitcoinSendCoin(accountID: "fixture", txid: hash, vout: index,
                            value: funding.outputs[index].value, address: a, previousTransaction: parent)
                        // 98k exercises Core 30+'s default policy; the other
                        // networks are checked at their exact message limits.
                        let size = chain == .bitcoin ? 98_000 : BitcoinSendOptions.maximumMessageBytes(chain)
                        let options = BitcoinSendOptions(replaceable: rbf, message: Data(repeating: 97, count: size))
                        let rate: Int64 = chain == .dogecoin ? 1_000_000 : 2000
                        func sign(rate: Int64) throws -> BitcoinSignedSend {
                            let plan = try BitcoinSendPlan.make(coins: [coin], recipient: destination, amount: 50_000_000,
                                change: change, ratePerKVByte: rate, network: .regtest, chain: chain, options: options)
                            return try chain == .bitcoincash
                                ? BitcoinCashSendSigner.sign(plan) { _ in .seed(seed, account: 0) }
                                : BitcoinSendSigner.sign(plan) { _ in .seed(seed, account: 0) }
                        }
                        var signed = try sign(rate: rate)
                        if chain != .dogecoin {
                            let result = try rpc.call("testmempoolaccept", [[signed.raw.hex]]) as! [[String: Any]]
                            XCTAssertEqual(result[0]["allowed"] as? Bool, true, "\(chain)/\(type): \(result[0]["reject-reason"] ?? "unknown")")
                        }
                        XCTAssertEqual(try rpc.call("sendrawtransaction", [signed.raw.hex]) as? String, signed.txid)
                        accepted += 1
                        if BitcoinSendOptions.supportsRBF(chain) {
                            let replacement = try sign(rate: rate * 4)
                            if rbf || chain == .bitcoin {
                                // Core 30+ full-RBF is deliberately also tested
                                // with signaling off. DOGE requires opt-in.
                                XCTAssertEqual(try rpc.call("sendrawtransaction", [replacement.raw.hex]) as? String, replacement.txid)
                                signed = replacement
                            } else {
                                XCTAssertThrowsError(try rpc.call("sendrawtransaction", [replacement.raw.hex]))
                            }
                        }
                        try mine(1)
                        let receipt = try rpc.call("getrawtransaction", [signed.txid, true]) as! [String: Any]
                        XCTAssertGreaterThan(receipt["confirmations"] as! Int, 0)
                        XCTAssertEqual(receipt["hex"] as? String, signed.raw.hex)
                    }
                }
            }
            print("Isolated \(chain.rawValue) standardness, exact message bytes, signing and mining passed")
        }
        XCTAssertEqual(accepted, 30)
    }
}

private struct OptionsNodeRPC {
    let chain: UTXONetwork
    var wallet: String { chain == .bitcoin ? "oath-options" : chain == .litecoin ? "oath-ltc-send" : "oath-bch-send" }
    func call(_ method: String, _ params: [Any]) throws -> Any {
        let process = Process(), out = Pipe(), err = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/docker")
        let args: [String]
        switch chain {
        case .bitcoin: args = ["oath-options-btc-regtest", "/core/bin/bitcoin-cli", "-regtest", "-datadir=/data"]
        case .dogecoin: args = ["oath-doge-send-regtest", "/doge/dogecoin-cli", "-regtest", "-rpcuser=oathregtest", "-rpcpassword=isolated-test-only"]
        case .litecoin: args = ["oath-options-ltc-regtest", "/ltc/litecoin-cli", "-regtest", "-datadir=/data"]
        case .bitcoincash: args = ["oath-bch-send-regtest", "/bchn/bitcoin-cli", "-regtest", "-datadir=/data"]
        }
        let walletOption = chain != .dogecoin && !["listwallets", "listwalletdir", "createwallet", "loadwallet"].contains(method) ? ["-rpcwallet=" + wallet] : []
        // stdin avoids ARG_MAX for Bitcoin's large OP_RETURN transaction hex.
        process.arguments = ["exec", "-i"] + args + walletOption + ["-stdin", method]
        let body = try params.map { value -> String in
            if let s = value as? String { return s }
            return String(data: try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), encoding: .utf8)!
        }.joined(separator: "\n") + (params.isEmpty ? "" : "\n")
        process.standardInput = input; process.standardOutput = out; process.standardError = err
        try process.run()
        input.fileHandleForWriting.write(Data(body.utf8)); try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // Regtest-only error text never includes parameters or raw bytes.
            let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "OptionsNodeRPC." + chain.rawValue + "." + method, code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(error.prefix(300))])
        }
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) ?? String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
