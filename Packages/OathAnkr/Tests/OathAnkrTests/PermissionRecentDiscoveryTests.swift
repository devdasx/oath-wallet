import XCTest
@testable import OathAnkr

private actor RecentPermissionTransport: AnkrTransport {
    let network: EVMSendNetwork
    let allowance: String
    let wrongNetwork: Bool
    let failWindow: Int?
    var ranges = [(UInt64, UInt64)]()
    var indexCalls = 0
    var logHosts = [String]()
    var archiveOffline = false
    func makeArchiveUnavailable() { archiveOffline = true }
    var primaryLookbackMessage: String?
    var primaryFailures = 0
    var archiveRanges: [(UInt64, UInt64)] = []
    func rejectOlderPrimaryPages(_ message: String) { primaryLookbackMessage = message }
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
                logHosts.append(request.url?.host ?? "")
                if archiveOffline && request.url?.host == "api.node.glif.io" { return (Data(), 503) }
                if request.url?.host == "archive.example" { archiveRanges.append((lower, upper)) }
                XCTAssertEqual(filter["topics"].array?.count, 2)
                if request.url?.host == "primary.example", lower < 24_640, let primaryLookbackMessage {
                    primaryFailures += 1
                    reply["error"] = .object(["code": .number("1"), "message": .string(primaryLookbackMessage)])
                } else if network.isFilecoin && upper - lower > 360 {
                    reply["error"] = .object(["code": .number("-32005"),
                        "message": .string("block range exceeds maximum of 360 (got " + String(upper - lower) + ")")])
                } else if ranges.count == failWindow {
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
    func testFilecoinProviderLimitPreservesFullWindowAndVerifiesAllowance() async throws {
        let transport = RecentPermissionTransport(network: .filecoin)
        let scan = try await run(transport, network: .filecoin)
        let ranges = await transport.ranges
        XCTAssertEqual(ranges.first?.1, 25_000)
        XCTAssertEqual(ranges.last?.0, 5_001)
        XCTAssertEqual(ranges.reduce(UInt64(0)) { $0 + $1.1 - $1.0 + 1 }, 20_000)
        XCTAssertLessThanOrEqual(ranges.count, 56)
        XCTAssertTrue(ranges.allSatisfy { $0.1 - $0.0 <= 360 })
        for (newer, older) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(older.1 + 1, newer.0)
        }
        XCTAssertEqual(scan.permissions.map(\.amount), ["12"])
        XCTAssertEqual(scan.coverage, .partial)
    }

    func testFilecoinUsesANKRForRecentPagesAndAsBackupForArchive() async throws {
        let transport = RecentPermissionTransport(network: .filecoin)
        let client = try EVMSendClient(network: .filecoin, endpoints: [
            URL(string: "https://rpc.ankr.com/filecoin/fixture")!, URL(string: "https://api.node.glif.io/rpc/v1")!
        ], transport: transport)
        await transport.makeArchiveUnavailable()
        let scan = try await PermissionDiscovery(apiKey: "fixture", transport: transport).evm(
            network: .filecoin, owner: "0x" + String(repeating: "1", count: 40), client: client)
        let ranges = await transport.ranges, hosts = await transport.logHosts
        XCTAssertEqual(ranges.first?.1, 25_000)
        XCTAssertEqual(ranges.last?.0, 5_001)
        let byStart = Dictionary(grouping: zip(ranges, hosts), by: { $0.0.0 })
        XCTAssertEqual(byStart.count, 56)
        for (from, calls) in byStart {
            XCTAssertEqual(calls.map { $0.1 }, 25_000 - from >= 2_878 ? ["api.node.glif.io", "rpc.ankr.com"] : ["rpc.ankr.com"])
            XCTAssertEqual(Set(calls.map { $0.0.1 }).count, 1)
        }
        XCTAssertEqual(scan.permissions.map(\.amount), ["12"])
    }

    func testLiveFilecoinPermissionScanCoversAllRecentEpochs() async throws {
        guard let path = ProcessInfo.processInfo.environment["OATH_FILECOIN_PERMISSION_TEST_CONFIG"] else {
            throw XCTSkip("Opt-in read-only Filecoin permission scan")
        }
        let config = try PropertyListDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let key = try XCTUnwrap(config["AnkrAPIKey"])
        let transport = FilecoinReadOnlyTransport()
        let client = try EVMSendClient(network: .filecoin, endpoints: [
            URL(string: "https://rpc.ankr.com/filecoin")!.appendingPathComponent(key),
            URL(string: "https://api.node.glif.io/rpc/v1")!
        ], transport: transport)
        let discovery = try PermissionDiscovery(apiKey: key, transport: transport)
        let scan = try await discovery.evm(network: .filecoin, owner: "0x" + String(repeating: "1", count: 40), client: client)
        XCTAssertEqual(scan.coverage, .partial)
        let rejected = await transport.lookbackRejections
        XCTAssertEqual(rejected, 0, "Permission discovery must route older pages before the gateway rejects them")
        let ranges = await transport.completedRanges
        XCTAssertEqual(ranges.count, 56)
        XCTAssertEqual(ranges.reduce(UInt64(0)) { $0 + $1.1 - $1.0 + 1 }, 20_000)
        for (newer, older) in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(older.1 + 1, newer.0) }
    }

    func testFilecoinArchiveRetriesExactRangeOnlyForHistoricalLookback() async throws {
        for (message, usesArchive) in [("bad tipset height: lookbacks of more than 24h0m0s are disallowed", true),
                                       ("unrelated rejection", false)] {
            let transport = RecentPermissionTransport(network: .filecoin)
            await transport.rejectOlderPrimaryPages(message)
            let client = try EVMSendClient(network: .filecoin, endpoints: [
                URL(string: "https://primary.example")!, URL(string: "https://archive.example")!
            ], transport: transport)
            let discovery = try PermissionDiscovery(apiKey: "fixture", transport: transport)
            let scan = try await discovery.evm(network: .filecoin, owner: "0x" + String(repeating: "1", count: 40), client: client)
            XCTAssertEqual(scan.coverage, .partial)
            XCTAssertEqual(scan.permissions.map(\.amount), ["12"])
            let archive = await transport.archiveRanges, failed = await transport.primaryFailures
            XCTAssertEqual(failed, 1)
            if usesArchive {
                XCTAssertEqual(archive.first?.0, 24_281)
                XCTAssertEqual(archive.first?.1, 24_640)
                XCTAssertEqual(archive.last?.0, 5_001)
                XCTAssertEqual(archive.count, 55)
            } else { XCTAssertTrue(archive.isEmpty) }
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

private actor FilecoinReadOnlyTransport: AnkrTransport {
    let upstream = AnkrHTTPTransport()
    var completedRanges: [(UInt64, UInt64)] = []
    var lookbackRejections = 0
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let batch = try JSONDecoder().decode([SolanaJSON].self, from: XCTUnwrap(request.httpBody))
        guard batch.allSatisfy({ ["eth_chainId", "eth_blockNumber", "eth_getLogs", "eth_call"].contains($0["method"].string) }) else {
            throw PermissionError.malformed
        }
        let response = try await upstream.send(request)
        if let query = batch.first(where: { $0["method"].string == "eth_getLogs" }),
           let filter = query["params"].array?.first, response.1 == 200 {
            let results = try JSONDecoder().decode([SolanaJSON].self, from: response.0)
            if results.contains(where: { $0["error"]["message"].string == "bad tipset height: lookbacks of more than 24h0m0s are disallowed" }) { lookbackRejections += 1 }
            if results.contains(where: { $0["id"] == query["id"] && $0["result"].array != nil }) {
                completedRanges.append((try EVMSendClient.uint(filter["fromBlock"]), try EVMSendClient.uint(filter["toBlock"])))
            }
        }
        return response
    }
}
