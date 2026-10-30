import XCTest
@testable import OathAnkr

private actor CeloLagTransport: AnkrTransport {
    let network: EVMSendNetwork
    let failures: Int
    let code: Int
    var calls = [SolanaJSON]()
    init(network: EVMSendNetwork = .celo, failures: Int, code: Int = -32019) {
        self.network = network; self.failures = failures; self.code = code
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: request.httpBody!)
        func chain(_ id: SolanaJSON) -> SolanaJSON {
            .object(["jsonrpc": .string("2.0"), "id": id, "result": .string("0x" + String(network.chainID, radix: 16))])
        }
        guard let batch = body.array else { return (try JSONEncoder().encode(chain(body["id"])), 200) }
        let call = batch[1]
        calls.append(call)
        var result: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": call["id"]]
        if calls.count <= failures {
            result["error"] = .object(["code": .number(String(code)), "message": .string("block is out of range")])
        } else { result["result"] = .string("0x1") }
        return (try JSONEncoder().encode(SolanaJSON.array([chain(batch[0]["id"]), .object(result)])), 200)
    }
}

@MainActor final class CeloSendRetryTests: XCTestCase {
    private func client(_ transport: CeloLagTransport, network: EVMSendNetwork = .celo) throws -> EVMSendClient {
        try EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport)
    }

    func testReplicaLagRetriesIdenticalPinnedReads() async throws {
        for method in ["eth_getBalance", "eth_call", "eth_getTransactionCount", "eth_getBlockByNumber", "eth_estimateGas"] {
            let transport = CeloLagTransport(failures: 1)
            let params: [SolanaJSON] = [.string("fixture"), .string("0x123")]
            let result = try await client(transport).rpc(method, params)
            XCTAssertEqual(result, .string("0x1"))
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 2)
            XCTAssertEqual(calls[0], calls[1], "Retries must preserve the original block and parameters")
        }
    }

    func testPersistentReplicaLagStopsAfterThreeAttempts() async throws {
        let transport = CeloLagTransport(network: .celoSepolia, failures: 20)
        do {
            _ = try await client(transport, network: .celoSepolia).rpc("eth_getBalance", [.string("0x123")])
            XCTFail("Persistent errors must propagate")
        } catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32019)) }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 3)
    }

    func testBroadcastOtherNetworksAndDeterministicRejectionsAreNotRetried() async throws {
        for (network, method, code) in [(EVMSendNetwork.celo, "eth_sendRawTransaction", -32019),
                                      (.ethereum, "eth_getBalance", -32019),
                                      (.celo, "eth_call", -32000)] {
            let transport = CeloLagTransport(network: network, failures: 20, code: code)
            do {
                _ = try await client(transport, network: network).rpc(method, [])
                XCTFail("Rejection must propagate")
            } catch { XCTAssertEqual(error as? EVMSendError, .rpc(code)) }
            let calls = await transport.calls
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testCancellationDuringBackoffStopsRetries() async throws {
        let transport = CeloLagTransport(failures: 20)
        let client = try client(transport)
        let task = Task { try await client.rpc("eth_getBalance", []) }
        while await transport.calls.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await transport.calls
        XCTAssertEqual(calls.count, 1)
    }
}
