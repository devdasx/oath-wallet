import Foundation
import XCTest
@testable import OathBitcoin

private final class HistoryBatchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var counts: [String: [Int]] = [:]
    func enter(_ server: String, count: Int) {
        lock.withLock {
            active += 1; peak = max(peak, active)
            counts[server, default: []].append(count)
        }
    }
    func leave() { lock.withLock { active -= 1 } }
    var result: (Int, [String: [Int]]) { lock.withLock { (peak, counts) } }
}

private struct HistoryBatchWire: ElectrumTransport {
    let server: ElectrumServer
    let probe: HistoryBatchProbe
    let transactions: [String: Data]
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if requests.first?["method"]?.string == "server.version" {
            return try await StubTransport(.empty).exchange(data, timeout: timeout)
        }
        guard requests.count <= server.batchLimit else { throw BitcoinError.invalidResponse }
        probe.enter(server.host, count: requests.count)
        defer { probe.leave() }
        try await Task.sleep(for: .milliseconds(30))
        let rows = try requests.map { request -> JSONValue in
            let result: JSONValue
            if request["method"]?.string == "blockchain.block.header" {
                let height = request["params"]!.array!.first!.integer!
                var header = Data(repeating: 0, count: 80)
                header.replaceSubrange(68..<72, with: BitcoinWire.little(UInt32(1_700_000_000 + height)))
                result = .string(header.hex)
            } else {
                let id = request["params"]!.array!.first!.string!
                guard let raw = transactions[id] else { throw BitcoinError.invalidResponse }
                result = .string(raw.hex)
            }
            return .object(["id": request["id"]!, "result": result])
        }
        return try JSONEncoder().encode(JSONValue.array(rows.reversed()))
    }
}

final class ElectrumHistoryBatchTests: XCTestCase, @unchecked Sendable {
    private let servers: [ElectrumServer] = [.init("large-a", batchLimit: 300), .init("small", batchLimit: 12), .init("large-b", batchLimit: 300)]

    func testHeadersAreConcurrentRespectEachPeerLimitAndKeepEveryHeight() async throws {
        let probe = HistoryBatchProbe()
        let pool = ElectrumPool(servers: servers, makeTransport: { HistoryBatchWire(server: $0, probe: probe, transactions: [:]) })
        let heights = Array(Int64(1)...240)
        let times = try await pool.blockTimes(heights: heights)
        XCTAssertEqual(times.count, heights.count)
        for height in heights { XCTAssertEqual(times[height], Double(1_700_000_000 + height)) }
        let (peak, counts) = probe.result
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertTrue(counts["large-a", default: []].contains(40))
        XCTAssertTrue(counts["small", default: []].allSatisfy { $0 <= 12 })
        await pool.close()
    }

    func testLargeTransactionBackfillHasBoundedConcurrencyAndExactBytes() async throws {
        var fixtures: [String: Data] = [:]
        for index in 0..<400 {
            var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
            raw += BitcoinWire.little(UInt32(index)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
            raw += BitcoinWire.little(UInt64(100_000)) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
            fixtures[try BitcoinTransactions.txid(raw)] = raw
        }
        let data = fixtures, probe = HistoryBatchProbe()
        let pool = ElectrumPool(servers: servers, makeTransport: { HistoryBatchWire(server: $0, probe: probe, transactions: data) })
        let result = try await pool.transactions(txids: Array(data.keys).sorted())
        XCTAssertEqual(result, data)
        let (peak, counts) = probe.result
        XCTAssertGreaterThan(peak, 1)
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertTrue(counts["large-a", default: []].contains(40))
        XCTAssertTrue(counts["small", default: []].allSatisfy { $0 <= 12 })
        await pool.close()
    }

    func testHeaderBackfillFailsOverAndRespectsTheSmallerBackupLimit() async throws {
        let probe = HistoryBatchProbe()
        let pool = ElectrumPool(servers: [.init("blocked"), .init("backup", batchLimit: 12)], maximumConnections: 1) { server in
            if server.host == "blocked" { return StubTransport(.failure(.timeout)) }
            return HistoryBatchWire(server: server, probe: probe, transactions: [:])
        }
        let heights = Array(Int64(1)...120)
        let times = try await pool.blockTimes(heights: heights)
        XCTAssertEqual(times.count, heights.count)
        let attempts = await pool.diagnostics()
        XCTAssertEqual(attempts.first?.error, .timeout)
        XCTAssertTrue(probe.result.1["backup", default: []].allSatisfy { $0 <= 12 })
        for height in heights { XCTAssertEqual(times[height], Double(1_700_000_000 + height)) }
        await pool.close()
    }

    func testCancellingLargeBackfillReleasesLeasesForTheNextRequest() async throws {
        let probe = HistoryBatchProbe()
        let pool = ElectrumPool(servers: servers, makeTransport: { HistoryBatchWire(server: $0, probe: probe, transactions: [:]) })
        let work = Task { try await pool.blockTimes(heights: Array(Int64(1)...4_000)) }
        try await Task.sleep(for: .milliseconds(15))
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled backfill returned") }
        catch is CancellationError { }
        let times = try await pool.blockTimes(heights: [42])
        XCTAssertEqual(times[42], 1_700_000_042)
        XCTAssertLessThanOrEqual(probe.result.0, 3)
        await pool.close()
    }

}
