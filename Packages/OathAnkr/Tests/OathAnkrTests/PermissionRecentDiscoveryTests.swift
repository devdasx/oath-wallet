import XCTest
@testable import OathAnkr

private actor RecentPermissionTransport: AnkrTransport {
    let network: EVMSendNetwork
    let allowance: String
    let wrongNetwork: Bool
    let failWindow: Int?
    var ranges = [(UInt64, UInt64)]()
    var indexCalls = 0
    private func hex(_ value: UInt64) -> SolanaJSON { .string("0x" + String(value, radix: 16)) }
    init(network: EVMSendNetwork, allowance: String = "12", wrongNetwork: Bool = false, failWindow: Int? = nil) {
        self.network = network; self.allowance = allowance; self.wrongNetwork = wrongNetwork; self.failWindow = failWindow
    }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let body = try JSONDecoder().decode(SolanaJSON.self, from: XCTUnwrap(request.httpBody))
        if body["method"].string == "ankr_getLogs" {
            indexCalls += 1
            return (try JSONEncoder().encode(SolanaJSON.object([
                "jsonrpc": .string("2.0"), "id": .number("1"),
                "error": .object(["code": .number("-32601"), "message": .string("Unsupported method")])])), 200)
        }
        var response = [SolanaJSON]()
        for row in try XCTUnwrap(body.array) {
            var reply: [String: SolanaJSON] = ["jsonrpc": .string("2.0"), "id": row["id"]]
            switch row["method"].string {
            case "eth_chainId": reply["result"] = hex(wrongNetwork ? 999 : network.chainID)
            case "eth_blockNumber": reply["result"] = hex(25_000)
            case "eth_getLogs":
                let filter = try XCTUnwrap(row["params"].array?.first)
                let lower = try EVMSendClient.uint(filter["fromBlock"]), upper = try EVMSendClient.uint(filter["toBlock"])
                ranges.append((lower, upper))
                XCTAssertEqual(filter["topics"].array?.count, 2)
                if ranges.count == failWindow {
                    reply["error"] = .object(["code": .number("-32000"), "message": .string("Unavailable")])
                } else {
                    let owner = "0x" + String(repeating: "1", count: 40), spender = "0x" + String(repeating: "2", count: 40)
                    reply["result"] = .array([.object([
                        "address": .string("0x" + String(repeating: "3", count: 40)),
                        "blockNumber": hex(upper),
                        "topics": .array([.string(PermissionDiscovery.approval),
                            .string("0x" + TronSendCrypto.hex(try EVMPermissionRemoval.word(owner))),
                            .string("0x" + TronSendCrypto.hex(try EVMPermissionRemoval.word(spender)))])])])
                }
            case "eth_call": reply["result"] = .string("0x" + TronSendCrypto.hex(try TronSendCrypto.uint256(allowance)))
            default: throw PermissionError.malformed
            }
            response.append(.object(reply))
        }
        return (try JSONEncoder().encode(SolanaJSON.array(response)), 200)
    }
}

@MainActor final class PermissionRecentDiscoveryTests: XCTestCase {
    private func run(_ transport: RecentPermissionTransport, network: EVMSendNetwork) async throws -> PermissionScan {
        try await PermissionDiscovery(apiKey: "test", transport: transport).evm(network: network,
            owner: "0x" + String(repeating: "1", count: 40),
            client: EVMSendClient(network: network, endpoints: [URL(string: "https://fixture.example")!], transport: transport))
    }
    func testRPCOnlyChainBoundsScanAndDeduplicatesVerifiedPermissions() async throws {
        let transport = RecentPermissionTransport(network: .arc)
        let scan = try await run(transport, network: .arc)
        XCTAssertEqual(scan.coverage, .partial)
        XCTAssertEqual(scan.permissions.count, 1); XCTAssertEqual(scan.permissions.first?.amount, "12")
        let ranges = await transport.ranges
        XCTAssertEqual(ranges.count, 20); XCTAssertEqual(ranges.first?.1, 25_000); XCTAssertEqual(ranges.last?.0, 5_001)
        for index in ranges.indices {
            XCTAssertEqual(ranges[index].1 - ranges[index].0, 999)
            if index > 0 { XCTAssertEqual(ranges[index].1 + 1, ranges[index - 1].0) }
        }
    }
    func testMissingIndexFallsBackAndExcludesRevokedAllowance() async throws {
        let transport = RecentPermissionTransport(network: .ethereum, allowance: "0")
        let scan = try await run(transport, network: .ethereum)
        XCTAssertEqual(scan.coverage, .partial); XCTAssertTrue(scan.permissions.isEmpty)
        let calls = await transport.indexCalls; XCTAssertEqual(calls, 1)
    }
    func testWrongRPCChainFailsClosed() async throws {
        let transport = RecentPermissionTransport(network: .arc, wrongNetwork: true)
        do { _ = try await run(transport, network: .arc); XCTFail("Misrouted provider accepted") }
        catch { XCTAssertEqual(error as? EVMSendError, .wrongNetwork) }
        let ranges = await transport.ranges; XCTAssertTrue(ranges.isEmpty)
    }
    func testUnavailableFirstWindowDoesNotProduceSuccessfulEmptyScan() async throws {
        let transport = RecentPermissionTransport(network: .arc, failWindow: 1)
        do { _ = try await run(transport, network: .arc); XCTFail("Unavailable provider accepted") }
        catch { XCTAssertEqual(error as? EVMSendError, .rpc(-32000)) }
    }
    func testLaterWindowFailureKeepsVerifiedCandidatesWithPartialCoverage() async throws {
        let transport = RecentPermissionTransport(network: .arc, failWindow: 2)
        let scan = try await run(transport, network: .arc)
        XCTAssertEqual(scan.coverage, .partial); XCTAssertEqual(scan.permissions.count, 1)
        let ranges = await transport.ranges; XCTAssertEqual(ranges.count, 2)
    }
}
