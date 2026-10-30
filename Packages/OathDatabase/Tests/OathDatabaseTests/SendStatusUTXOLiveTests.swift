import Foundation
import XCTest
@testable import OathBitcoin
@testable import OathDatabase

private struct StatusTestnetRPC: BitcoinSendStatusReading {
    let chain: UTXONetwork
    struct Request<P: Encodable>: Encodable { let method: String; let params: P }
    func call<P: Encodable, R: Decodable>(_ method: String, _ params: P, as: R.Type) async throws -> R {
        let data = try JSONEncoder().encode(Request(method: method, params: params)), chain = chain
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tools/SendStatusTestnetTransport.py")
        let result = try await Task.detached {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("status-rpc-" + UUID().uuidString + ".json")
            let response = URL(fileURLWithPath: file.path + ".response")
            defer { try? FileManager.default.removeItem(at: file); try? FileManager.default.removeItem(at: response) }
            try data.write(to: file)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [script.path, chain.rawValue, file.path]
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BitcoinError.unavailable }
            return try Data(contentsOf: response)
        }.value
        return try JSONDecoder().decode(R.self, from: result)
    }
    struct History: Decodable { let txid: String; let height: Int64 }
    func query(scriptHashes: [String]) async throws -> [BitcoinAddressState] {
        let rows = try await call("query", scriptHashes, as: [[History]].self)
        return rows.map { .init(confirmed: 0, unconfirmed: 0, history: $0.map { .init(txid: $0.txid, height: $0.height) }, unspent: []) }
    }
    func transactions(txids: [String]) async throws -> [String: Data] {
        try await call("transactions", txids, as: [String:String].self).mapValues {
            guard let raw = Data(hex: $0) else { throw BitcoinError.invalidResponse }; return raw
        }
    }
    func blockTimes(heights: [Int64]) async throws -> [Int64: Double] {
        let rows = try await call("times", heights, as: [String:Double].self)
        return Dictionary(uniqueKeysWithValues: try rows.map { key,value in
            guard let height = Int64(key) else { throw BitcoinError.invalidResponse }; return (height,value)
        })
    }
    struct Address: Codable { let address: String; let scriptHash: String; let type: Int; let change: UInt32; let index: UInt32 }
    struct Output: Decodable { let tx_hash: String; let tx_pos: Int; let value: Int64; let raw: String; let address: Address }
}

extension SendStatusLiveTests {
    /// Resume a journaled test without signing or broadcasting another payment.
    func testLiveBitcoinCashResumeStatus() async throws {
        guard ProcessInfo.processInfo.environment["OATH_STATUS_LIVE"] == "1",
              let hash = ProcessInfo.processInfo.environment["OATH_STATUS_BCH_RESUME_HASH"],
              hash.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw XCTSkip("Explicit testnet journal hash required")
        }
        struct Proof: Decodable { let plan: BitcoinSendPlan; let raw: Data; let hash: String }
        let file = URL(fileURLWithPath: "/tmp/oath-bch-public/status-" + hash + ".json")
        let proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: file))
        guard proof.plan.chain == .bitcoincash, proof.plan.network == .chipnet,
              proof.hash == hash, try BitcoinTransactions.txid(proof.raw, network: .bitcoincash) == hash else {
            throw BitcoinError.wrongNetwork
        }
        let rpc = StatusTestnetRPC(chain: .bitcoincash), plan = proof.plan, raw = proof.raw
        try await track(chain: "bitcoincash", reference: "native", decimals: 8,
            sender: try XCTUnwrap(plan.coins.first?.address.address), recipient: plan.recipient,
            amount: String(plan.recipientAmount), hash: hash, plan: plan, signed: raw,
            planTable: "bitcoinSendPlans", rawPayload: raw, timeoutSeconds: 90) { db, id in
                if let receipt = try await BitcoinSendStatus.read(raw: raw, plan: plan, client: rpc) {
                    try await db.settleBitcoinSend(id, confirmation: receipt)
                }
            }
    }
    func testLiveBitcoinCashRestartStatus() async throws { try await liveUTXO(.bitcoincash, directory: "/tmp/oath-bch-public", network: .chipnet) }
    func testLiveLitecoinRestartStatus() async throws { try await liveUTXO(.litecoin, directory: "/tmp/oath-ltc-public", network: .testnet) }
    func testLiveBitcoinRestartStatus() async throws { try await liveUTXO(.bitcoin, directory: "/tmp/oath-send-testnet4", network: .testnet4) }
    func testLiveDogecoinRestartStatus() async throws { try await liveUTXO(.dogecoin, directory: "/tmp/oath-doge-public", network: .testnet) }
    private func liveUTXO(_ chain: UTXONetwork, directory: String, network: BitcoinSendNetwork) async throws {
        guard ProcessInfo.processInfo.environment["OATH_STATUS_LIVE"] == "1" else { throw XCTSkip("Explicit public testnet opt-in required") }
        let root = URL(fileURLWithPath: directory)
        var seed = try Data(contentsOf: root.appendingPathComponent("test-seed.bin"))
        defer { seed.resetBytes(in: 0..<seed.count) }
        let descriptor = try chain.wallet(seed: seed), rpc = StatusTestnetRPC(chain: chain)
        func derive(_ type: BitcoinAddressType, _ change: UInt32, _ index: UInt32) throws -> BitcoinDerivedAddress {
            let branch = try XCTUnwrap(descriptor.branches.first { $0.type == type && $0.change == change })
            return try BitcoinKeys.addresses(branch: branch, range: index..<(index+1))[0]
        }
        var addresses: [StatusTestnetRPC.Address] = []
        if chain == .litecoin || chain == .bitcoincash {
            let j = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("public.json"))) as? [String:Any])
            for row in try XCTUnwrap(j["addresses"] as? [[String:Any]]) {
                addresses.append(.init(address: row["address"] as! String, scriptHash: row["scriptHash"] as! String,
                    type: row["type"] as? Int ?? descriptor.defaultType.rawValue, change: UInt32(row["change"] as? Int ?? 0), index: UInt32(row["index"] as? Int ?? 0)))
            }
        } else {
            let a = try derive(descriptor.defaultType, 0, 0)
            addresses = [.init(address: try BitcoinSendPlan.address(a, on: network, chain: chain),scriptHash: a.scriptHash,type:a.type.rawValue,change:0,index:0)]
        }
        // Previous runs move faucet funds to the dedicated recipient/change
        // below. Include those controlled branches when repeating the test;
        // checking only the initial faucet address incorrectly reports empty.
        for branch: UInt32 in [0, 1] {
            let a = try derive(descriptor.defaultType, branch, 900)
            if !addresses.contains(where: { $0.scriptHash == a.scriptHash }) {
                addresses.append(.init(address: try BitcoinSendPlan.address(a, on: network, chain: chain),
                    scriptHash: a.scriptHash, type: a.type.rawValue, change: branch, index: 900))
            }
        }
        let outputs = try await rpc.call("funding", addresses, as: [StatusTestnetRPC.Output].self)
        guard !outputs.isEmpty else { throw BitcoinSendError.insufficientFunds }
        let coins = try outputs.map { o -> BitcoinSendCoin in
            let a = try derive(XCTUnwrap(BitcoinAddressType(rawValue:o.address.type)),o.address.change,o.address.index)
            return .init(accountID:"sender",txid:o.tx_hash,vout:o.tx_pos,value:o.value,address:a,previousTransaction:try XCTUnwrap(Data(hex:o.raw)))
        }
        let target = try derive(descriptor.defaultType,0,900), change = try derive(descriptor.defaultType,1,900)
        let amount = chain == .dogecoin ? 100_000_000 : chain == .litecoin ? 100_000 : 1000
        let plan = try BitcoinSendPlan.make(coins:coins,recipient:BitcoinSendPlan.address(target,on:network,chain:chain),amount:Int64(amount),change:change,
            ratePerKVByte:chain == .dogecoin ? 1_000_000:1000,network:network,chain:chain)
        let signed: BitcoinSignedSend
        if chain == .bitcoincash { signed = try BitcoinCashSendSigner.sign(plan) { _ in .seed(seed,account:0) } }
        else { signed = try BitcoinSendSigner.sign(plan) { _ in .seed(seed,account:0) } }
        // Persist proof artifacts (public signed transaction and plan, no keys)
        // before relay, so a rerun can inspect an interrupted test safely.
        let proof = root.appendingPathComponent("status-" + signed.txid + ".json")
        struct Evidence: Encodable { let plan:BitcoinSendPlan;let raw:Data;let hash:String }
        try JSONEncoder().encode(Evidence(plan:plan,raw:signed.raw,hash:signed.txid)).write(to:proof)
        let hash = try await rpc.call("broadcast",[signed.raw.hex],as:String.self)
        XCTAssertEqual(hash,signed.txid)
        try await track(chain:chain.rawValue,reference:"native",decimals:8,sender:coins[0].address.address,recipient:plan.recipient,
            amount:String(plan.recipientAmount),hash:signed.txid,plan:plan,signed:signed.raw,planTable:"bitcoinSendPlans",rawPayload:signed.raw,timeoutSeconds:1200) { db,id in
                if let receipt = try await BitcoinSendStatus.read(raw:signed.raw,plan:plan,client:rpc) {
                    try await db.settleBitcoinSend(id,confirmation:receipt)
                }
            }
    }
}
