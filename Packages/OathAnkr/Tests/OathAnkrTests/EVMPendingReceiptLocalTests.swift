import XCTest
@testable import OathAnkr

private actor ReceiptMiningGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !open { await withCheckedContinuation { waiters.append($0) } } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume() } }
}

private actor ReceiptMiningTransport: AnkrTransport {
    let endpoint = URL(string: "http://127.0.0.1:19586")!
    let gate = ReceiptMiningGate()
    var armed = false
    var sawPending = false, sawMinedReceipt = false
    func arm(_ value: Bool) { armed = value }
    func send(_ original: URLRequest) async throws -> (Data, Int) {
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(original.httpBody)).array ?? []
        let transaction = calls.contains { $0["method"].string == "eth_getTransactionByHash" }
        let receipt = calls.contains { $0["method"].string == "eth_getTransactionReceipt" }
        if armed && receipt { await gate.wait() }
        var request = original; request.url = endpoint
        let (data, response) = try await URLSession.shared.data(for: request)
        if armed && transaction {
            let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array ?? []
            sawPending = rows.contains { row in
                calls.contains { $0["method"].string == "eth_getTransactionByHash" && $0["id"] == row["id"] }
                && !row["result"].isNull && row["result"]["blockHash"] == .null && row["result"]["blockNumber"] == .null
            }
            // Mine only after capturing the real pending transaction response.
            // The concurrent receipt read then observes the real mined result.
            _ = try await control("anvil_mine", [.string("0x80")])
            await gate.release()
        }
        if armed && receipt {
            let rows = try JSONDecoder().decode(SolanaJSON.self, from: data).array ?? []
            sawMinedReceipt = rows.contains { !$0["result"]["blockHash"].isNull }
        }
        return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
    }
    func control(_ method: String, _ params: [SolanaJSON]) async throws -> SolanaJSON {
        var request = URLRequest(url: endpoint); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(SolanaJSON.object(["jsonrpc": .string("2.0"), "id": .number("1"), "method": .string(method), "params": .array(params)]))
        let (data, _) = try await URLSession.shared.data(for: request)
        let row = try JSONDecoder().decode(SolanaJSON.self, from: data)
        XCTAssertTrue(row["error"].isNull); return row["result"]
    }
}

final class EVMPendingReceiptLocalTests: XCTestCase, @unchecked Sendable {
    func testRealMiningBetweenConcurrentReadsCannotFalselyFailOrConfirm() async throws {
        guard ProcessInfo.processInfo.environment["OATH_EVM_PENDING_RECEIPT_LOCAL"] == "1" else {
            throw XCTSkip("Dedicated local Anvil node with mining disabled on port 19586")
        }
        let feed = ReceiptMiningTransport(), key = Data(repeating: 1, count: 32)
        let sender = try EVMSendCrypto.address(privateKey: key)
        let recipient = try EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32))
        _ = try await feed.control("anvil_setBalance", [.string(sender), .string("0x56bc75e2d63100000")])
        _ = try await feed.control("evm_setNextBlockTimestamp", [.number(String(Int(Date.now.timeIntervalSince1970)))])
        _ = try await feed.control("evm_mine", [])
        let client = try EVMSendClient(network: .ethereum, endpoints: [URL(string: "https://fixture.example")!], transport: feed)
        let plan = try await client.quote(sender: sender, recipient: recipient, reference: "native", decimals: 18, amount: "12345")
        let signed = try EVMSendCrypto.sign(plan, privateKey: key)
        _ = try await client.submit(signed, plan: plan, reconcileFirst: false)
        await feed.arm(true)
        let racing = try await client.status(signed, plan: plan)
        XCTAssertEqual(racing.outcome, .accepted); XCTAssertNil(racing.inclusion); XCTAssertNil(racing.fee)
        let pending = await feed.sawPending, mined = await feed.sawMinedReceipt
        XCTAssertTrue(pending); XCTAssertTrue(mined)
        await feed.arm(false)
        let consistent = try await client.status(signed, plan: plan)
        XCTAssertEqual(consistent.outcome, .confirmed)
        let received = try await client.balance(owner: recipient, reference: "native")
        XCTAssertEqual(received, plan.amount)
        let nonce = try await feed.control("eth_getTransactionCount", [.string(sender), .string("latest")])
        XCTAssertEqual(try EVMSendClient.uint(nonce), plan.nonce + 1)
    }
}
