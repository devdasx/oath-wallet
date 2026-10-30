import Foundation
import XCTest
@testable import OathBitcoin

private actor BatchTraffic {
    var sizes: [String: [Int]] = [:]
    var active = 0
    var peak = 0
    func begin(host: String, count: Int) {
        sizes[host, default: []].append(count)
        active += 1; peak = max(peak, active)
    }
    func end() { active -= 1 }
}

private actor BatchWire: ElectrumTransport {
    let server: ElectrumServer
    let traffic: BatchTraffic
    let failAt: Int?
    let bias: Int64
    var batches = 0
    init(_ server: ElectrumServer, traffic: BatchTraffic, failAt: Int? = nil, bias: Int64 = 0) {
        self.server = server; self.traffic = traffic; self.failAt = failAt; self.bias = bias
    }
    nonisolated func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let calls = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: data).array)
        if calls.first?["method"]?.string == "server.version" {
            return try await StubTransport(.empty).exchange(data, timeout: timeout)
        }
        guard calls.count <= server.batchLimit else { throw BitcoinError.batchUnsupported }
        batches += 1
        await traffic.begin(host: server.host, count: calls.count)
        do {
            try await Task.sleep(for: .milliseconds(5))
            if batches == failAt { throw BitcoinError.disconnected }
            let values = try calls.map { call -> JSONValue in
                let hash = try XCTUnwrap(call["params"]?.array?.first?.string)
                let amount = try XCTUnwrap(Int64(hash.suffix(8), radix: 16)) + 1 + bias
                let value: JSONValue
                switch call["method"]?.string {
                case "blockchain.scripthash.get_balance":
                    value = .object(["confirmed": .integer(amount), "unconfirmed": .integer(0)])
                case "blockchain.scripthash.get_history":
                    value = .array([.object(["tx_hash": .string(hash), "height": .integer(100)])])
                case "blockchain.scripthash.listunspent":
                    value = .array([.object(["tx_hash": .string(hash), "height": .integer(100),
                        "tx_pos": .integer(0), "value": .integer(amount)])])
                default: throw BitcoinError.invalidResponse
                }
                return .object(["id": call["id"]!, "result": value])
            }
            await traffic.end()
            return try JSONEncoder().encode(JSONValue.array(values.reversed()))
        } catch {
            await traffic.end()
            throw error
        }
    }
}

final class ElectrumBatchingTests: XCTestCase, @unchecked Sendable {
    private func hashes(_ count: Int) -> [String] { (0..<count).map { String(format: "%064x", $0) } }

    func testSmallFallbackDoesNotThrottleLargePeer() async throws {
        let traffic = BatchTraffic()
        let pool = ElectrumPool(servers: [.init("large", batchLimit: 300), .init("small", batchLimit: 12)], maximumConnections: 1) {
            BatchWire($0, traffic: traffic)
        }
        let result = try await pool.query(scriptHashes: hashes(100))
        XCTAssertEqual(result.map(\.confirmed), Array(1...100).map(Int64.init))
        let sizes = await traffic.sizes
        XCTAssertEqual(sizes["large"], [300])
        XCTAssertNil(sizes["small"])
        await pool.close()
    }

    func testFailoverRechunksToSmallPeerWithoutLosingOrReorderingAddresses() async throws {
        let traffic = BatchTraffic()
        let pool = ElectrumPool(servers: [.init("large", batchLimit: 300), .init("small", batchLimit: 12)], maximumConnections: 1) {
            BatchWire($0, traffic: traffic, failAt: $0.host == "large" ? 1 : nil)
        }
        let result = try await pool.query(scriptHashes: hashes(100))
        XCTAssertEqual(result.map(\.confirmed), Array(1...100).map(Int64.init))
        let sizes = await traffic.sizes
        XCTAssertEqual(sizes["small"], Array(repeating: 12, count: 25))
        await pool.close()
    }

    func testFailedPartialPeerResultsAreDiscarded() async throws {
        let traffic = BatchTraffic()
        let pool = ElectrumPool(servers: [.init("small", batchLimit: 12), .init("large", batchLimit: 300)], maximumConnections: 1) {
            BatchWire($0, traffic: traffic, failAt: $0.host == "small" ? 2 : nil, bias: $0.host == "small" ? 10_000 : 0)
        }
        let result = try await pool.query(scriptHashes: hashes(100))
        XCTAssertEqual(result.map(\.confirmed), Array(1...100).map(Int64.init))
        let sizes = await traffic.sizes
        XCTAssertEqual(sizes["small"], [12, 12]); XCTAssertEqual(sizes["large"], [300])
        await pool.close()
    }

    func testExplicitLargePeerSupportsFiveThousandCompleteAddressChecks() async throws {
        let traffic = BatchTraffic()
        let pool = ElectrumPool(servers: [.init("large", batchLimit: 15_000)]) { BatchWire($0, traffic: traffic) }
        let result = try await pool.query(scriptHashes: hashes(5_000))
        XCTAssertEqual(result.map(\.confirmed), Array(1...5_000).map(Int64.init))
        let sizes = await traffic.sizes
        XCTAssertEqual(sizes["large"], [15_000])
        await pool.close()
    }

    func testNetworkBatchesRunConcurrentlyWithinPoolLimitAndStayOrdered() async throws {
        let traffic = BatchTraffic()
        let pool = ElectrumPool(servers: [.init("a", batchLimit: 60), .init("b", batchLimit: 60), .init("c", batchLimit: 60)], maximumConnections: 2) {
            BatchWire($0, traffic: traffic)
        }
        let result = try await pool.query(scriptHashes: hashes(400))
        XCTAssertEqual(result.map(\.confirmed), Array(1...400).map(Int64.init))
        let peak = await traffic.peak
        XCTAssertEqual(peak, 2)
        await pool.close()
    }

    func testFullFrontierReducesPinnedSnapshotExchanges() async throws {
        let input = hashes(160)
        let oldTraffic = BatchTraffic(), newTraffic = BatchTraffic()
        // A production snapshot pins all reads to one peer. Model the previous
        // eight 20-address branch calls and compare identical validated states.
        let oldPool = ElectrumPool(servers: [.init("peer")], maximumConnections: 1) { BatchWire($0, traffic: oldTraffic) }
        let newPool = ElectrumPool(servers: [.init("peer")], maximumConnections: 1) { BatchWire($0, traffic: newTraffic) }
        let clock = ContinuousClock(), oldStart = clock.now
        let old = try await BitcoinConcurrent.map(Array(stride(from: 0, to: 160, by: 20)), limit: 8) { start in
            try await oldPool.query(scriptHashes: Array(input[start..<start + 20]))
        }.flatMap { $0 }
        let oldElapsed = oldStart.duration(to: clock.now), newStart = clock.now
        let new = try await newPool.query(scriptHashes: input)
        let newElapsed = newStart.duration(to: clock.now)
        XCTAssertEqual(old, new)
        let oldSizes = await oldTraffic.sizes["peer"], newSizes = await newTraffic.sizes["peer"]
        XCTAssertEqual(oldSizes, Array(repeating: 60, count: 8))
        XCTAssertEqual(newSizes, [300, 180])
        // Wall time is evidence, not a flaky pass/fail threshold on a busy host.
        print("Synthetic 160-address snapshot: old=\(oldElapsed), batched=\(newElapsed); exchanges 8 -> 2")
        await oldPool.close(); await newPool.close()
    }

    func testCancellationStopsSchedulingRemainingBatches() async throws {
        let traffic = BatchTraffic()
        let pool = ElectrumPool(servers: [.init("a", batchLimit: 60), .init("b", batchLimit: 60)], maximumConnections: 2) {
            BatchWire($0, traffic: traffic)
        }
        let input = hashes(5_000)
        let work = Task { try await pool.query(scriptHashes: input) }
        for _ in 0..<100 {
            if await traffic.active == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled scan returned partial balances") }
        catch { XCTAssertTrue(error is CancellationError) }
        let sizes = await traffic.sizes, active = await traffic.active
        XCTAssertLessThan(sizes.values.reduce(0) { $0 + $1.count }, 250)
        XCTAssertEqual(active, 0)
        await pool.close()
    }
}
