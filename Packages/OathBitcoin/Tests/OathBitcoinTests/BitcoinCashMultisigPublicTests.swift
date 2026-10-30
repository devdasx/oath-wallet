import XCTest
import CryptoKit
@testable import OathBitcoin

/// Opt-in disposable public testnet fixture. Secrets remain in a mode-0700 /tmp folder.
final class BitcoinCashMultisigPublicTests: XCTestCase {
    private let policies = [(1, 2), (2, 3), (3, 5), (7, 15), (15, 15), (2, 2), (1, 2)]
    private func root() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["OATH_BCH_MULTISIG_PUBLIC_DIR"], path.hasPrefix("/tmp/") else {
            throw XCTSkip("Disposable BitcoinCash public testnet fixture is opt-in")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return root
    }
    private func keys(_ step: Int, root: URL) throws -> [BitcoinMultisigKey] {
        var seed = try Data(contentsOf: root.appendingPathComponent("test-seed.bin"))
        defer { seed.resetBytes(in: 0..<seed.count) }
        guard seed.count == 32 else { throw BitcoinMultisigError.invalidKey }
        return try (0..<policies[step].1).map { i in
            var bytes = Data(HMAC<SHA256>.authenticationCode(for: Data("bch-multisig-\(step)-\(i)".utf8), using: SymmetricKey(data: seed)))
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            // Fixed WIF, mixed WIF/HD, all-HD and maximum-key policies.
            if step == 0 || (step != 5 && i % 2 == 0) {
                return .wif(try BitcoinCashKeys.wif(bytes: bytes, compressed: true))
            }
            return .seed(bytes)
        }
    }
    private func address(_ step: Int, change: UInt32 = 0, index: UInt32 = 0, root: URL) throws -> BitcoinDerivedAddress {
        let policy = try BitcoinMultisig.wallet(required: policies[step].0, keys: keys(step, root: root), network: .bitcoincash)
        let branch = policy.branches.first { $0.change == change } ?? policy.branches[0]
        let index: UInt32 = branch.isHD ? index : 0
        return try BitcoinKeys.addresses(branch: branch, range: index..<(index + 1))[0]
    }
    private func publicInfo(_ a: BitcoinDerivedAddress) throws -> [String: Any] {
        ["address": try BitcoinSendPlan.address(a, on: .chipnet, chain: .bitcoincash),
         "scriptHash": a.scriptHash, "type": a.type.rawValue, "change": a.change, "index": a.index]
    }
    func testPreparePublicWallet() throws {
        let root = try root(), seedPath = root.appendingPathComponent("test-seed.bin")
        if !FileManager.default.fileExists(atPath: seedPath.path) {
            var bytes = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            defer { bytes.resetBytes(in: 0..<bytes.count) }
            try bytes.write(to: seedPath, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: seedPath.path)
        }
        let a = try address(0, root: root)
        let publicPath = root.appendingPathComponent("public.json")
        if !FileManager.default.fileExists(atPath: publicPath.path) {
            try JSONSerialization.data(withJSONObject: ["addresses": [publicInfo(a)], "step": 0], options: .prettyPrinted).write(to: publicPath)
        }
        print("Disposable BitcoinCash multisig testnet funding address: " + (try BitcoinSendPlan.address(a, on: .chipnet, chain: .bitcoincash)))
    }
    func testSignPublicTransfer() throws {
        let root = try root()
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("public.json"))) as! [String: Any]
        let step = info["step"] as! Int
        guard step < policies.count - 1 else { throw XCTSkip("Six public multisig transfers already signed") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("utxos.json"))) as! [[String: Any]]
        let coins = try rows.map { row in
            BitcoinSendCoin(accountID: "disposable", txid: row["tx_hash"] as! String, vout: row["tx_pos"] as! Int,
                value: (row["value"] as! NSNumber).int64Value,
                address: try address(step, change: UInt32(row["change"] as! Int), index: UInt32(row["index"] as! Int), root: root),
                previousTransaction: Data(hex: row["raw"] as! String)!)
        }
        let total = try BitcoinSendPlan.sum(coins.map(\.value), maximumMoney: UTXONetwork.bitcoincash.maximumMoney)
        let target = try address(step + 1, root: root), change = try address(step, change: 1, index: 7, root: root)
        let plan = try BitcoinSendPlan.make(coins: coins, recipient: BitcoinSendPlan.address(target, on: .chipnet, chain: .bitcoincash),
            amount: total, change: change, ratePerKVByte: 2000, network: .chipnet, chain: .bitcoincash)
        let signed = try BitcoinMultisig.sign(plan, required: policies[step].0, keys: keys(step, root: root), network: .bitcoincash)
        XCTAssertEqual(plan.changeAmount, 0)
        XCTAssertEqual(plan.remainingBalance, 0)
        XCTAssertEqual(plan.recipientAmount + signed.fee, total)
        try JSONSerialization.data(withJSONObject: ["network": "chipnet", "step": step, "raw": signed.raw.hex,
            "txid": signed.txid, "fee": signed.fee, "inputs": coins.count, "nextAddresses": [publicInfo(target)],
            "required": policies[step].0, "keys": policies[step].1, "balanceBefore": total, "received": plan.recipientAmount],
            options: .prettyPrinted).write(to: root.appendingPathComponent("signed.json"))
        print("Signed disposable BitcoinCash multisig testnet transfer \(step + 1), \(policies[step].0)-of-\(policies[step].1)")
    }
}
