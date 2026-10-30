import Foundation
import XCTest
@testable import OathAnkr

private actor AdvancingIoTeXTransport: AnkrTransport {
    let live = AnkrHTTPTransport()
    var delayedHead = false
    var stateTags: [String] = []
    var stateHosts: Set<String> = []
    var usedFallback = false
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let calls = request.httpBody.flatMap { try? JSONDecoder().decode(SolanaJSON.self, from: $0).array } ?? []
        if request.url?.host == "babel-api.mainnet.iotex.io" { usedFallback = true }
        for call in calls where ["eth_call", "eth_getBalance"].contains(call["method"].string ?? "") {
            if let tag = call["params"].array?.last?.string, tag != "latest" {
                stateTags.append(tag)
                stateHosts.insert(request.url?.host ?? "")
            }
        }
        let response = try await live.send(request)
        if !delayedHead, request.url?.host == "rpc.ankr.com",
           calls.contains(where: { $0["method"].string == "eth_getBlockByNumber" && $0["params"].array?.first?.string == "latest" }) {
            delayedHead = true
            // Recreate the original race: ANKR's tip advances before state reads.
            try await Task.sleep(for: .seconds(4))
        }
        return response
    }
}

final class IoTeXPinnedLiveTests: XCTestCase, @unchecked Sendable {
    func testAdvancingANKRTipKeepsCompleteExactPublicAccountBalances() async throws {
        guard ProcessInfo.processInfo.environment["OATH_IOTEX_PINNED_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public account read; no signing or user wallet")
        }
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["OATH_ANKR_CONFIG"])
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let owner = "0xcf3aad8dc49158fd15b59a6dae41f1f52236aef3"
        let transport = AdvancingIoTeXTransport()
        let inventory = try await IndexedEVMClient(chain: .iotex, apiKey: key, transport: transport).inventory(owner: owner)
        XCTAssertTrue(inventory.complete)
        XCTAssertGreaterThan(inventory.holdings.count, 9)
        let tag = "0x" + String(inventory.block, radix: 16)
        let tags = await transport.stateTags, hosts = await transport.stateHosts
        let delayed = await transport.delayedHead, fallback = await transport.usedFallback
        XCTAssertTrue(delayed); XCTAssertFalse(fallback)
        XCTAssertEqual(Set(tags), [tag]); XCTAssertEqual(hosts, ["archive-mainnet.iotex.io"])
        // Re-read every balance at the same height, then independently confirm
        // the anchor block and advancing tip against the configured ANKR node.
        var calls: [[String: Any]] = inventory.holdings.enumerated().map { i, holding in
            ["jsonrpc": "2.0", "id": i + 1,
             "method": holding.token.reference == "native" ? "eth_getBalance" : "eth_call",
             "params": holding.token.reference == "native" ? [owner, tag] :
                [["to": holding.token.reference, "data": "0x70a08231" + String(repeating: "0", count: 24) + owner.dropFirst(2)], tag]]
        }
        func read(_ url: URL, _ calls: [[String: Any]]) async throws -> [SolanaJSON] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("OathWallet/1.0", forHTTPHeaderField: "User-Agent")
            request.httpBody = try JSONSerialization.data(withJSONObject: calls)
            let (data, status) = try await AnkrHTTPTransport().send(request)
            XCTAssertEqual(status, 200)
            return try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
        }
        let balances = try await read(URL(string: "https://archive-mainnet.iotex.io")!, calls)
        for (i, holding) in inventory.holdings.enumerated() {
            let row = try XCTUnwrap(balances.first { $0["id"].integer == UInt64(i + 1) })
            XCTAssertEqual(holding.amount, try IndexedEVMIdentity.amount(row["result"]))
        }
        calls = [["jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber", "params": [tag, false]],
                 ["jsonrpc": "2.0", "id": 2, "method": "eth_blockNumber", "params": []]]
        let anchor = try await read(URL(string: "https://rpc.ankr.com/iotex")!.appendingPathComponent(key), calls)
        XCTAssertEqual(anchor.first { $0["id"].integer == 1 }?["result"]["hash"].string, inventory.blockHash)
        XCTAssertGreaterThan(try IndexedEVMIdentity.height(XCTUnwrap(anchor.first { $0["id"].integer == 2 })["result"]), inventory.block)
        print("IoTeX live pinned snapshot: ANKR tip advanced; all \(inventory.holdings.count) exact balances verified at one matching block")
    }
}
