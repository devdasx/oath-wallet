import Foundation
import XCTest
@testable import OathBitcoin

private final class RejectedSnapshotPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let failure: BitcoinError
    init(_ failure: BitcoinError) { self.failure = failure }
    var connections: Int { lock.withLock { count } }
    func connect() -> any ElectrumTransport {
        lock.withLock { count += 1 }
        return RejectedSnapshotTransport(failure: failure)
    }
}

private struct RejectedSnapshotTransport: ElectrumTransport {
    let failure: BitcoinError
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data { throw failure }
}

final class ElectrumSnapshotProviderRecoveryLiveTests: XCTestCase, @unchecked Sendable {
    func testRepeatedSnapshotsUseLiveHealthyPeerAfterReportedFailures() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ELECTRUM_PROVIDER_LIVE"] == "1" else {
            throw XCTSkip("Opt-in public transaction reads with an injected peer failure; no signing or broadcast")
        }
        func get(_ path: String) async throws -> Data {
            let request = URLRequest(url: URL(string: "https://blockstream.info/api/" + path)!,
                cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 4_194_304 else {
                throw BitcoinError.invalidResponse
            }
            return data
        }
        let block = String(decoding: try await get("block-height/100000"), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = try JSONDecoder().decode([String].self, from: await get("block/" + block + "/txids"))
        let txids = Array(ids.prefix(4))
        XCTAssertEqual(txids.count, 4)
        var expected: [String: Data] = [:]
        for id in txids {
            let bytes = try await get("tx/" + id + "/raw")
            XCTAssertEqual(try BitcoinTransactions.txid(bytes), id)
            expected[id] = bytes
        }
        let healthy = try XCTUnwrap(ElectrumServer.publicMainnet.first)
        for failure in [BitcoinError.batchUnsupported, .disconnected, .timeout] {
            let rejected = RejectedSnapshotPeer(failure)
            let pool = ElectrumPool(servers: [.init("fault-fixture"), healthy], transactionFallback: nil) { server in
                server.host == "fault-fixture" ? rejected.connect() : ElectrumWire(server: server)
            }
            do {
                for _ in 0..<3 {
                    // The production coordinator verifies the same live peer's
                    // header before and after the complete four-transaction read.
                    let snapshot = try await pool.withStableSnapshot { try await $0.transactions(txids: txids) }
                    XCTAssertEqual(snapshot.value, expected)
                    XCTAssertGreaterThan(snapshot.tip.height, 800_000)
                }
                XCTAssertEqual(rejected.connections, 1, "A healthy refresh must not reconnect to the rejected peer")
                print("LIVE SNAPSHOT RECOVERY \(failure): 3 stable snapshots, 4 exact transactions each, rejectedPeerConnections=\(rejected.connections), HTTPFallback=false")
            } catch {
                await pool.close()
                throw error
            }
            await pool.close()
        }
    }
}
