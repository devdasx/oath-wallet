import Foundation
import XCTest
@testable import OathBitcoin

final class BitcoinTransactionFallbackTests: XCTestCase, @unchecked Sendable {
    private func fixture(_ value: UInt64 = 100_000) throws -> (String, Data) {
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(value) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
        return (try BitcoinTransactions.txid(raw), raw)
    }
    func testMissingElectrumTransactionRecoversOnlyVerifiedBytes() async throws {
        let (hash, bytes) = try fixture()
        let fallback = BitcoinTransactionFallback { request in
            XCTAssertNil(request.httpBody); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return bytes
        }
        let pool = ElectrumPool(servers: [.init("missing")], transactionFallback: { try await fallback.transactions(txids: $0) }) {
            _ in StubTransport(.failure(.server(code: 2)))
        }
        let result = try await pool.transactions(txids: [hash])
        XCTAssertEqual(result[hash], bytes); await pool.close()
    }
    func testWrongHashRetriesIndependentSourceAndCannotPoisonCache() async throws {
        let (hash, bytes) = try fixture(), (_, wrong) = try fixture(200_000)
        let fallback = BitcoinTransactionFallback { request in request.url!.host == "blockstream.info" ? wrong : bytes }
        let result = try await fallback.transactions(txids: [hash]); XCTAssertEqual(result[hash], bytes)
        let corrupt = BitcoinTransactionFallback { _ in wrong }
        do { _ = try await corrupt.transactions(txids: [hash]); XCTFail() }
        catch { XCTAssertEqual(error as? BitcoinError, .unavailable) }
    }
    func testCancellationAndWrongChainCannotFallBack() async throws {
        let (hash, _) = try fixture()
        let canceled = BitcoinTransactionFallback { _ in throw CancellationError() }
        do { _ = try await canceled.transactions(txids: [hash]); XCTFail() } catch is CancellationError { }
        let otherChain = ElectrumPool(servers: [.init("missing")], network: .dogecoin,
            transactionFallback: { _ in XCTFail("BTC archive used for DOGE"); return [:] }) {
                _ in StubTransport(.failure(.server(code: 2)), network: .dogecoin)
            }
        do { _ = try await otherChain.transactions(txids: [hash]); XCTFail() }
        catch { XCTAssertEqual(error as? BitcoinError, .server(code: 2)) }
        await otherChain.close()
    }
    func testLivePublicBitcoinArchiveWithElectrumUnavailable() async throws {
        guard ProcessInfo.processInfo.environment["OATH_UTXO_FEES_LIVE"] == "1" else { throw XCTSkip("Read-only public historical transaction") }
        // Public Bitcoin genesis coinbase; no user wallet identifiers.
        let hash = "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
        let pool = ElectrumPool(servers: [.init("unavailable")], transactionFallback: {
            try await BitcoinTransactionFallback.shared.transactions(txids: $0)
        }) { _ in StubTransport(.failure(.server(code: 2))) }
        let result = try await pool.transactions(txids: [hash])
        XCTAssertEqual(try BitcoinTransactions.txid(XCTUnwrap(result[hash])), hash)
        await pool.close()
    }
}
