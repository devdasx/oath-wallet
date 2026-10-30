import XCTest
@testable import OathAnkr

private actor PendingReceiptFeed: AnkrTransport {
    enum Mode: Sendable { case pending, partial, absent, wrongReceipt, wrongTransaction, minedMismatch }
    let base: EVMSendFixtureTransport
    var mode: Mode?
    init(network: EVMSendNetwork) { base = .init("confirmed", network: network) }
    func configure(_ plan: EVMSendPlan, _ signed: EVMSignedSend, mode: Mode?) async {
        await base.configure(plan, signed); self.mode = mode
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, status) = try await base.send(request)
        guard let mode else { return (data, status) }
        let calls = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody)).array ?? []
        let replies = try XCTUnwrap(JSONDecoder().decode(SolanaJSON.self, from: data).array)
        let mapped = replies.map { reply -> SolanaJSON in
            guard case .object(var row) = reply, case .object(var result) = row["result"],
                  let call = calls.first(where: { $0["id"] == row["id"] }) else { return reply }
            if call["method"].string == "eth_getTransactionByHash" {
                result["blockHash"] = .null
                if mode != .partial { result["blockNumber"] = .null }
                if mode == .absent { result.removeValue(forKey: "blockNumber") }
                if mode == .wrongTransaction { result["to"] = result["from"] }
                if mode == .minedMismatch {
                    result["blockHash"] = .string("0x" + String(repeating: "b", count: 64))
                    result["blockNumber"] = .string("0x65")
                }
            }
            if call["method"].string == "eth_getTransactionReceipt", mode == .wrongReceipt {
                result["transactionHash"] = .string("0x" + String(repeating: "b", count: 64))
            }
            row["result"] = .object(result); return .object(row)
        }
        return (try JSONEncoder().encode(SolanaJSON.array(mapped)), status)
    }
}

final class EVMPendingReceiptTests: XCTestCase, @unchecked Sendable {
    func testReceiptArrivingAfterPendingTransactionReadRemainsAcceptedUntilConsistent() async throws {
        for network in EVMSendNetwork.allCases {
            let feed = PendingReceiptFeed(network: network)
            let client = try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: feed)
            let key = Data(repeating: 1, count: 32)
            let plan = try await client.quote(sender: EVMSendCrypto.address(privateKey: key), recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "12345")
            let signed = try EVMSendCrypto.sign(plan, privateKey: key)
            await feed.configure(plan, signed, mode: .pending)
            let first = try await client.status(signed, plan: plan)
            XCTAssertEqual(first.outcome, .accepted, network.rawValue)
            XCTAssertNil(first.inclusion); XCTAssertNil(first.fee)
            await feed.configure(plan, signed, mode: nil)
            let next = try await client.status(signed, plan: plan)
            XCTAssertEqual(next.outcome, .confirmed, network.rawValue)
            XCTAssertNotNil(next.fee)
            let counts = await feed.base.counts()
            XCTAssertEqual(counts.1, 0, "Status reconciliation must never broadcast")
        }
    }
    func testMalformedOrMismatchedEvidenceStillFails() async throws {
        for mode: PendingReceiptFeed.Mode in [.partial, .absent, .wrongReceipt, .wrongTransaction, .minedMismatch] {
            let feed = PendingReceiptFeed(network: .base)
            let client = try EVMSendClient(network: .base, endpoints: [URL(string: "https://fixture.example")!], transport: feed)
            let key = Data(repeating: 1, count: 32)
            let plan = try await client.quote(sender: EVMSendCrypto.address(privateKey: key), recipient: EVMSendCrypto.address(privateKey: Data(repeating: 2, count: 32)), reference: "native", decimals: 18, amount: "12345")
            let signed = try EVMSendCrypto.sign(plan, privateKey: key)
            await feed.configure(plan, signed, mode: mode)
            do { _ = try await client.status(signed, plan: plan); XCTFail("Invalid evidence accepted") }
            catch { XCTAssertEqual(error as? EVMSendError, .changed) }
        }
    }
}
