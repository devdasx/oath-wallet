import XCTest
@testable import OathAnkr

private actor DuplicateLocalTransport: AnkrTransport {
    var broadcasts = 0, duplicates = 0
    let endpoint = URL(string: "http://127.0.0.1:19585")!
    func send(_ original: URLRequest) async throws -> (Data, Int) {
        var request = original; request.url = endpoint
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array ?? []
        if calls.contains(where: { $0["method"].string == "eth_sendRawTransaction" }) {
            broadcasts += 1
            let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array ?? []
            if rows.contains(where: { $0["error"]["code"].text == "-32003" && $0["error"]["message"].string == "transaction already imported" }) { duplicates += 1 }
        }
        return (data, status)
    }
    func control(_ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "method": .string(method), "params": .array(params)]))
        let (data, _) = try await URLSession.shared.data(for: request)
        let reply = try JSONDecoder().decode(SolanaJSON.self, from: data)
        XCTAssertTrue(reply["error"].isNull); return reply["result"]
    }
}

/// A dedicated loopback node with mining disabled; no public network or user key.
final class EVMDuplicateBroadcastLocalTests: XCTestCase, @unchecked Sendable {
    func testRealNodeDuplicateIsReconciledAndTransfersExactlyOnce() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_DUPLICATE_LOCAL"] == "1" else {
            throw XCTSkip("Opt-in isolated Anvil instance on loopback port 19585")
        }
        let feed = DuplicateLocalTransport(), key = Data(repeating: 1, count: 32)
        let sender = try EVMSendCrypto.address(privateKey: key)
        let recipient = try EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32))
        _ = try await feed.control("anvil_setBalance", [.string(sender), .string("0x56bc75e2d63100000")])
        _ = try await feed.control("evm_setNextBlockTimestamp", [.number(String(Int(Date.now.timeIntervalSince1970)))])
        _ = try await feed.control("evm_mine", [])
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://loopback.example")!], transport: feed)
        let before = try await client.balance(owner: recipient, reference: "native")
        let plan = try await client.quote(sender: sender, recipient: recipient, reference: "native", decimals: 18, amount: "12345")
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        let first = try await client.submit(signed, plan: plan, reconcileFirst: false)
        XCTAssertEqual(first.outcome, .accepted)
        let duplicate = try await client.submit(signed, plan: plan, reconcileFirst: false)
        XCTAssertEqual(duplicate.outcome, .accepted); XCTAssertEqual(duplicate.hash, first.hash)
        let broadcasts = await feed.broadcasts, duplicates = await feed.duplicates
        XCTAssertEqual(broadcasts, 2); XCTAssertEqual(duplicates, 1, "Must exercise a real node duplicate error")
        _ = try await feed.control("anvil_mine", [.string("0x80")])
        let mined = try await client.status(signed, plan: plan)
        XCTAssertEqual(mined.outcome, .confirmed)
        let after = try await client.balance(owner: recipient, reference: "native")
        XCTAssertEqual(try EVMSendAmount.subtract(after, before), plan.amount)
        let nonce = try await feed.control("eth_getTransactionCount", [.string(sender), .string("latest")])
        XCTAssertEqual(try EVMSendClient.uint(nonce), plan.nonce + 1)
    }
}
