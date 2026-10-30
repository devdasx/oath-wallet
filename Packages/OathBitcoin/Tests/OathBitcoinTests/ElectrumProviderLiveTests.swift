import Foundation
import XCTest
@testable import OathBitcoin

final class ElectrumProviderLiveTests: XCTestCase, @unchecked Sendable {
    func testEachDefaultPeerReadsVerifiedPublicTransactionBatchWithoutHTTPRecovery() async throws {
        guard ProcessInfo.processInfo.environment["OATH_ELECTRUM_PROVIDER_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only individual TLS provider check; no wallet, signing or broadcast")
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
        // The current reports concern four-transaction requests. Validate the
        // full batch, including independent bytes, rather than one happy read.
        let txids = Array(ids.prefix(4))
        XCTAssertEqual(txids.count, 4)
        var expected: [String: Data] = [:]
        for txid in txids {
            let raw = try await get("tx/" + txid + "/raw")
            XCTAssertEqual(try BitcoinTransactions.txid(raw), txid)
            expected[txid] = raw
        }
        for server in ElectrumServer.publicMainnet {
            // No archive or peer rotation can conceal an individual outage.
            let pool = ElectrumPool(servers: [server], transactionFallback: nil) { ElectrumWire(server: $0) }
            let start = ContinuousClock.now
            do {
                let before = try await pool.chainTip()
                let bytes = try await pool.transactions(txids: txids)
                let after = try await pool.chainTip()
                XCTAssertEqual(bytes, expected, server.host)
                XCTAssertGreaterThanOrEqual(after.height, before.height, server.host)
                let attempts = await pool.diagnostics()
                XCTAssertTrue(attempts.allSatisfy { $0.error == nil }, server.host)
                XCTAssertTrue(attempts.contains { $0.requestCount == 4 && $0.error == nil }, server.host)
                print("LIVE PEER \(server.host): network verified, 4 exact transactions matched, elapsed=\(start.duration(to: .now))")
            } catch {
                XCTFail("Default peer \(server.host) failed: \((error as? BitcoinError).map(String.init(describing:)) ?? "transport")")
            }
            await pool.close()
        }
    }
}
