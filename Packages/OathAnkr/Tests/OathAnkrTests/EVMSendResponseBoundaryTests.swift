import XCTest
@testable import OathAnkr

/// Synthetic responses only; no URLSession or real RPC endpoints are used.
private actor EVMResponseBoundaryFeed: AnkrTransport {
    let standaloneSize: Int
    let batchSize: Int?
    var broadcasts = 0
    var prechecks = 0

    init(standaloneSize: Int, batchSize: Int? = nil) {
        self.standaloneSize = standaloneSize
        self.batchSize = batchSize
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        let response: SolanaJSON
        let size: Int?
        if let calls = body.array {
            if calls.contains(where: { $0["method"].string == "eth_sendRawTransaction" }) {
                broadcasts += 1
            }
            response = .array(calls.map { .object([
                "jsonrpc": .string("2.0"), "id": $0["id"], "result": .string("0x1")
            ]) })
            size = batchSize
        } else {
            XCTAssertEqual(body["method"].string, "eth_chainId")
            prechecks += 1
            response = .object(["jsonrpc": .string("2.0"), "id": body["id"], "result": .string("0x1")])
            size = standaloneSize
        }
        var data = try JSONEncoder().encode(response)
        if let size {
            XCTAssertGreaterThanOrEqual(size, data.count)
            data.append(Data(repeating: 0x20, count: max(0, size - data.count)))
            XCTAssertEqual(data.count, size)
        }
        return (data, 200)
    }
}

final class EVMSendResponseBoundaryTests: XCTestCase, @unchecked Sendable {
    private func client(_ feed: EVMResponseBoundaryFeed) throws -> EVMSendClient {
        try .init(network: .ethereum, endpoints: [XCTUnwrap(URL(string: "https://rpc.example"))], transport: feed)
    }

    func testOversizedStandaloneChainReplyPreventsBroadcast() async throws {
        let feed = EVMResponseBoundaryFeed(standaloneSize: EVMSendClient.maximumRPCResponseBytes + 1)
        do {
            // Exercise the actual uncached pre-broadcast RPC path. The fixture
            // bytes are deliberately not a signed/fundable transaction.
            _ = try await client(feed).rpc("eth_sendRawTransaction", [.string("0x00")])
            XCTFail("Oversized standalone chain reply must be rejected before broadcast")
        } catch { XCTAssertEqual(error as? EVMSendError, .malformed) }
        let prechecks = await feed.prechecks, broadcasts = await feed.broadcasts
        XCTAssertEqual(prechecks, 1)
        XCTAssertEqual(broadcasts, 0, "Oversized standalone chain reply must not admit a broadcast")
    }

    func testExactStandaloneLimitRemainsAccepted() async throws {
        let feed = EVMResponseBoundaryFeed(standaloneSize: EVMSendClient.maximumRPCResponseBytes)
        let result = try await client(feed).rpc("eth_sendRawTransaction", [.string("0x00")])
        XCTAssertEqual(result, .string("0x1"))
        let prechecks = await feed.prechecks, broadcasts = await feed.broadcasts
        XCTAssertEqual(prechecks, 1); XCTAssertEqual(broadcasts, 1)
    }

    func testBatchBoundaryStillRejectsOneByteOverAndAcceptsExactLimit() async throws {
        for excess in [0, 1] {
            let feed = EVMResponseBoundaryFeed(standaloneSize: 100, batchSize: EVMSendClient.maximumRPCResponseBytes + excess)
            do {
                let result = try await client(feed).rpc("eth_getBalance", [.string("0x" + String(repeating: "1", count: 40)), .string("latest")])
                XCTAssertEqual(excess, 0); XCTAssertEqual(result, .string("0x1"))
            } catch {
                XCTAssertEqual(excess, 1); XCTAssertEqual(error as? EVMSendError, .malformed)
            }
            let prechecks = await feed.prechecks, broadcasts = await feed.broadcasts
            XCTAssertEqual(prechecks, 0); XCTAssertEqual(broadcasts, 0)
        }
    }
}
