import Foundation
import XCTest
@testable import OathBitcoin

private struct BroadcastReply: ElectrumTransport {
    let network: UTXONetwork
    let message: String
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if requests.first?["method"]?.string == "blockchain.transaction.broadcast" {
            return try JSONEncoder().encode(JSONValue.array([.object(["id": .integer(0),
                "error": .object(["code": .integer(1), "message": .string(message)])])]))
        }
        return try await StubTransport(.empty, network: network).exchange(data, timeout: timeout)
    }
}
final class ElectrumBroadcastRecoveryTests: XCTestCase, @unchecked Sendable {
    private func transaction() -> Data {
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(10_000)) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
        return raw
    }
    func testAlreadyConfirmedOrInMempoolAcknowledgesOnlySubmittedHash() async throws {
        for network in UTXONetwork.allCases {
            for message in ["the transaction was rejected by network rules.\n\ntransaction already in block chain\n[fixture]",
                            "Transaction outputs already in utxo set", "txn-already-known", "txn-already-in-mempool"] {
                let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in BroadcastReply(network: network, message: message) }
                let hash = try await pool.broadcastBitcoin(transaction())
                XCTAssertEqual(hash, try BitcoinTransactions.txid(transaction(), network: network))
                let attempts = await pool.diagnostics(); XCTAssertTrue(attempts.allSatisfy { $0.error == nil })
            }
        }
    }
    func testLastResortModeRequiresLookupInsteadOfTrustingKnownError() async throws {
        for network in UTXONetwork.allCases {
            let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in
                BroadcastReply(network: network, message: "txn-already-known")
            }
            do {
                _ = try await pool.broadcastBitcoin(transaction(), acceptAlreadyKnown: false)
                XCTFail("Last-resort broadcast accepted an error without exact-byte lookup")
            } catch { XCTAssertEqual(error as? BitcoinError, .server(code: 1)) }
            await pool.close()
        }
    }
    func testRejectionStaysFailureButDoesNotBlockReconciliation() async throws {
        for message in ["bad-txns-inputs-missingorspent", "txn-mempool-conflict", "inputs already spent", "insufficient fee"] {
            let pool = ElectrumPool(servers: [.init("fixture")]) { _ in BroadcastReply(network: .bitcoin, message: message) }
            do { _ = try await pool.broadcastBitcoin(transaction()); XCTFail("Rejected transaction accepted") }
            catch { XCTAssertEqual(error as? BitcoinError, .server(code: 1)) }
            let tip = try await pool.chainTip(); XCTAssertEqual(tip.height, 900_000, "Healthy peer was incorrectly quarantined")
        }
    }
    func testUnrelatedRequestCannotUseAlreadyKnownAcknowledgement() throws {
        let data = Data(#"[{"id":0,"error":{"code":1,"message":"txn-already-known"}}]"#.utf8)
        XCTAssertThrowsError(try ElectrumBatch.decode(data, ids: [0]))
        XCTAssertThrowsError(try ElectrumBatch.decode(data, ids: [0], broadcast: (id: 1, txid: "fixture")))
    }
}
