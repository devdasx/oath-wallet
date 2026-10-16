import Foundation
import XCTest
@testable import OathBitcoin

private actor RecoveryPosts {
    var count = 0
    func refused() throws -> String {
        count += 1
        throw URLError(.unsupportedURL) // This fixture never broadcasts, even on testnet.
    }
}

/// Public native DOGE testnet reads only. The old QED endpoint is unavailable.
/// This is a test adapter, not a new production broadcast/provider route.
private actor DogecoinTestnetReads {
    private var nextRead = ContinuousClock.now
    private(set) var rawReads = 0
    func rpc(_ method: String, _ params: [JSONValue]) async throws -> JSONValue {
        guard ["getblockhash", "getblockheader", "getrawtransaction"].contains(method) else {
            throw URLError(.unsupportedURL) // Never permit sendrawtransaction.
        }
        // The public, unauthenticated gateway can throttle closely spaced reads.
        let remaining = ContinuousClock.now.duration(to: nextRead)
        if remaining > .zero { try await Task.sleep(for: remaining) }
        try Task.checkCancellation()
        nextRead = .now.advanced(by: .seconds(2))
        if method == "getrawtransaction" { rawReads += 1 }
        var request = URLRequest(url: URL(string: "https://dogecoin-testnet.gateway.tatum.io")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST" // JSON-RPC reads; no transaction submission.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RPCRequest(id: 1, method: method, params: params))
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw BitcoinError.invalidResponse }
        guard status == 200 else {
            // Safe status only: make an external quota/outage distinguishable
            // from a byte-reconciliation regression without printing bodies.
            throw NSError(domain: "Oath.TestnetReadHTTP", code: status)
        }
        guard data.count <= 4_194_304 else {
            throw BitcoinError.invalidResponse
        }
        let reply = try JSONDecoder().decode(JSONValue.self, from: data)
        guard reply["id"]?.integer == 1, reply["error"] == nil || reply["error"] == .null,
              let result = reply["result"], result != .null else { throw BitcoinError.invalidResponse }
        return result
    }
}

final class UTXORecoveryLiveTests: XCTestCase, @unchecked Sendable {
    private func optIn() throws {
        guard ProcessInfo.processInfo.environment["OATH_UTXO_RECOVERY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in live recovery reads; all transaction POSTs are disabled")
        }
    }
    func testLiveBitcoinMainnetRecoveryUsesExactReadWithoutRebroadcast() async throws {
        try optIn()
        let hash = "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
        let existing = try await BitcoinTransactionFallback.shared.transactions(txids: [hash])
        let raw = try XCTUnwrap(existing[hash]), posts = RecoveryPosts()
        let client = UTXOBroadcastProvider(sources: { network in
            UTXOBroadcastProvider.liveSources(network).map { source in
                .init(name: source.name, delay: source.delay, submit: { _ in try await posts.refused() }, lookup: source.lookup)
            }
        })
        let start = ContinuousClock.now
        let accepted = await client.submit(raw, txid: hash, network: .bitcoin, reconcileFirst: true)
        XCTAssertTrue(accepted)
        let attempts = await posts.count; XCTAssertEqual(attempts, 0)
        print("LIVE RECOVERY bitcoin mainnet: exact existing bytes verified; zero POST attempts; elapsed=\(start.duration(to: .now))")
    }
    func testLiveBitcoinTestnet4Recovery() async throws {
        try await testnet(.bitcoin, base: "https://mempool.space/testnet4/api",
            genesis: "00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043")
    }
    func testLiveDogecoinMainnetRecoveryUsesExactReadWithoutRebroadcast() async throws {
        try optIn()
        let api = UTXOAPIProvider.providers(for: .dogecoin).first { $0.format == .blockcypher }!
        func discover(_ path: String) async throws -> Data {
            let request = URLRequest(url: URL(string: api.base.absoluteString + path)!,
                cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304 else {
                throw BitcoinError.invalidResponse
            }
            return data
        }
        struct Tip: Decodable { let name: String; let height: Int }
        let tip = try JSONDecoder().decode(Tip.self, from: await discover(""))
        XCTAssertEqual(tip.name, "DOGE.main")
        guard tip.name == "DOGE.main" else { throw BitcoinError.wrongNetwork }
        struct Block: Decodable { let txids: [String] }
        let block = try JSONDecoder().decode(Block.self, from: await discover("/blocks/\(tip.height - 6)?limit=2"))
        let hash = try XCTUnwrap(block.txids.last)
        let bytes = try await discover("/txs/\(hash)?includeHex=true")
        let raw = try XCTUnwrap(api.decodeRaw(bytes, txid: hash)), posts = RecoveryPosts()
        let client = UTXOBroadcastProvider(sources: { network in
            UTXOBroadcastProvider.liveSources(network).map { source in
                .init(name: source.name, delay: source.delay, submit: { _ in try await posts.refused() }, lookup: source.lookup)
            }
        })
        let start = ContinuousClock.now
        let accepted = await client.submit(raw, txid: hash, network: .dogecoin, reconcileFirst: true)
        XCTAssertTrue(accepted)
        let attempts = await posts.count; XCTAssertEqual(attempts, 0)
        print("LIVE RECOVERY dogecoin mainnet: exact public transaction bytes verified; zero POST attempts; elapsed=\(start.duration(to: .now))")
    }
    func testLiveDogecoinTestnetRecovery() async throws {
        try optIn()
        let reads = DogecoinTestnetReads()
        let genesis = try await reads.rpc("getblockhash", [.integer(0)])
        guard genesis.string == "bb0a78264637406b6360aad926284d544d7049f45189db5664f3c4d07350559e" else {
            throw BitcoinError.wrongNetwork
        }

        // QED's public faucet donation, linked in dogecoin/dogecoin discussion
        // #3626. Rediscover its confirmed bytes; no private fixture or signing.
        let hash = "b61a3de2b9805f922cb764342691758340087c51269f2779b3df55ec62978e85"
        let transaction = try await reads.rpc("getrawtransaction", [.string(hash), .bool(true)])
        guard transaction["txid"]?.string == hash,
              let confirmations = transaction["confirmations"]?.integer, confirmations > 0,
              let inputs = transaction["vin"]?.array, !inputs.isEmpty,
              inputs.allSatisfy({ $0["coinbase"] == nil && $0["txid"]?.string != nil }),
              let blockHash = transaction["blockhash"]?.string,
              let hex = transaction["hex"]?.string else { throw BitcoinError.invalidResponse }
        let block = try await reads.rpc("getblockheader", [.string(blockHash), .bool(true)])
        guard block["hash"]?.string == blockHash, let height = block["height"]?.integer, height > 0,
              let blockConfirmations = block["confirmations"]?.integer, blockConfirmations > 0 else {
            throw BitcoinError.invalidResponse
        }
        // Positive block confirmations establish main-chain membership. Keep
        // discovery to three reads so the fresh lookup fits the public quota.
        let decoder = UTXOAPIProvider(network: .dogecoin,
            base: URL(string: "https://dogecoin-testnet.gateway.tatum.io")!, format: .mempool)
        let raw = try XCTUnwrap(decoder.decodeRaw(Data(hex.utf8), txid: hash)), posts = RecoveryPosts()
        XCTAssertEqual(try BitcoinTransactions.txid(raw, network: .dogecoin), hash)

        // Finish discovery pacing before measuring the actual recovery window.
        try await Task.sleep(for: .seconds(2))
        let client = UTXOBroadcastProvider(sources: { _ in [
            .init(name: "verified-dogecoin-testnet-rpc", delay: .zero,
                  submit: { _ in try await posts.refused() }, lookup: { id in
                // Exercise a real read taking longer than the old 250ms window.
                try await Task.sleep(for: .milliseconds(600))
                let value: JSONValue
                do { value = try await reads.rpc("getrawtransaction", [.string(id), .bool(false)]) }
                catch {
                    // The live harness has no diagnostics uploader configured.
                    // Print only the safe code, never RPC params or raw bytes.
                    let failure = error as NSError
                    print("DOGE TESTNET lookup failed: domain=\(failure.domain), code=\(failure.code)")
                    throw error
                }
                guard let bytes = value.string else { throw BitcoinError.invalidResponse }
                return try decoder.decodeRaw(Data(bytes.utf8), txid: id)
            })
        ] })
        let start = ContinuousClock.now
        let accepted = await client.submit(raw, txid: hash, network: .dogecoin, reconcileFirst: true)
        let attempts = await posts.count, rawReads = await reads.rawReads
        XCTAssertTrue(accepted)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(rawReads, 2, "Discovery and a fresh network lookup, not cached fixture bytes")
        guard accepted, attempts == 0, rawReads == 2 else { return }
        print("LIVE RECOVERY dogecoin testnet: pinned genesis and canonical confirmed non-coinbase transaction; fresh exact-byte lookup; zero submission attempts; elapsed=\(start.duration(to: .now))")
    }
    private func testnet(_ chain: UTXONetwork, base: String, genesis: String) async throws {
        try optIn()
        // Only hardcoded public testnets. Sample discovery is read-only and
        // independent of the production reconciliation deadline under test.
        func get(_ path: String) async throws -> Data {
            let request = URLRequest(url: URL(string: base + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304 else {
                throw BitcoinError.invalidResponse
            }
            return data
        }
        let network = String(decoding: try await get("/block-height/0"), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(network, genesis)
        guard network == genesis else { throw BitcoinError.wrongNetwork }
        struct Block: Decodable { let id: String; let height: Int; let tx_count: Int }
        var blocks = try JSONDecoder().decode([Block].self, from: await get("/blocks"))
        var sample = blocks.first { $0.tx_count > 1 }
        for _ in 0..<3 where sample == nil {
            guard let height = blocks.last?.height, height > 0 else { break }
            blocks = try JSONDecoder().decode([Block].self, from: await get("/blocks/\(height - 1)"))
            sample = blocks.first { $0.tx_count > 1 }
        }
        let block = try XCTUnwrap(sample, "No recent public transfer available for this testnet check")
        let hashes = try JSONDecoder().decode([String].self, from: await get("/block/\(block.id)/txids"))
        guard hashes.count > 1 else { throw BitcoinError.invalidResponse }
        let hash = hashes[1] // Actual non-coinbase transaction, not a generated fixture.
        struct Status: Decodable { let confirmed: Bool; let block_hash: String? }
        let status = try JSONDecoder().decode(Status.self, from: await get("/tx/\(hash)/status"))
        XCTAssertTrue(status.confirmed); XCTAssertEqual(status.block_hash, block.id)
        let api = UTXOAPIProvider(network: chain, base: URL(string: base)!, format: .mempool)
        let publicBytes = try await get("/tx/\(hash)/hex")
        let raw = try XCTUnwrap(api.decodeRaw(publicBytes, txid: hash))
        XCTAssertEqual(try BitcoinTransactions.txid(raw, network: chain), hash)
        let posts = RecoveryPosts()
        let client = UTXOBroadcastProvider(sources: { _ in [
            .init(name: "verified-testnet-api", delay: .milliseconds(600), submit: { _ in try await posts.refused() }, lookup: { id in
                let request = api.lookupRequest(txid: id)
                XCTAssertTrue(request.httpMethod == nil || request.httpMethod == "GET")
                let data = try await UTXOAPIProvider.fetch(request, limit: 4_194_304, allowMissing: true)
                return try api.decodeRaw(data, txid: id)
            })
        ] })
        let start = ContinuousClock.now
        let accepted = await client.submit(raw, txid: hash, network: chain, reconcileFirst: true)
        XCTAssertTrue(accepted)
        let attempts = await posts.count; XCTAssertEqual(attempts, 0)
        print("LIVE RECOVERY \(chain.rawValue) testnet: pinned genesis, confirmed non-coinbase transaction, exact bytes, zero POST attempts; elapsed=\(start.duration(to: .now))")
    }
}
