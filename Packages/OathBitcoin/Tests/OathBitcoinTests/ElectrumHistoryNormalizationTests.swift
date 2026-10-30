import Foundation
import XCTest
@testable import OathBitcoin

private struct HistoryResponseWire: ElectrumTransport {
    let response: Data
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if requests.contains(where: { $0["method"]?.string?.contains("scripthash") == true }) {
            return response
        }
        return try await StubTransport(.empty, network: .dogecoin).exchange(data, timeout: timeout)
    }
}

final class ElectrumHistoryNormalizationTests: XCTestCase, @unchecked Sendable {
    private let a = String(repeating: "1", count: 64)
    private let b = String(repeating: "2", count: 64)

    func testCapturedPublicDogecoinHistoryMatchesBothIndependentPeers() async throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "dogecoin-duplicate-history", withExtension: "json"))
        let fixture = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let captured = try JSONEncoder().encode(XCTUnwrap(fixture["response"]))
        let reference = try JSONEncoder().encode(XCTUnwrap(fixture["expected"]))
        func read(_ response: Data) async throws -> [BitcoinAddressState] {
            let pool = ElectrumPool(servers: [.init("fixture")], network: .dogecoin) { _ in HistoryResponseWire(response: response) }
            let value = try await pool.query(scriptHashes: [a, b])
            let attempts = await pool.diagnostics()
            XCTAssertEqual(attempts.count, 1, "Duplicate records must not force a retry")
            XCTAssertNil(attempts.first?.error)
            await pool.close()
            return value
        }
        let expected = try await read(reference)
        let actual = try await read(captured)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.map { $0.history.count }, [13, 2])
    }

    func testRepeatedHistoryDoesNotDoubleCountFundsAndPreservesOrderForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            for height: Int64 in [100, 0, -1] {
                let first = BitcoinHistoryItem(txid: a, height: height)
                let second = BitcoinHistoryItem(txid: b, height: 101)
                let state = BitcoinAddressState(confirmed: height > 0 ? 50_000 : 0,
                    unconfirmed: height > 0 ? 0 : 50_000, history: [first, first, second, first],
                    unspent: [.init(txid: a, vout: 0, value: 50_000, height: max(0, height))])
                let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in StubTransport(.state(state), network: network) }
                let actual = try await pool.query(scriptHashes: [a])[0]
                XCTAssertEqual(actual.history, [first, second])
                XCTAssertEqual(actual.unspent, state.unspent)
                XCTAssertEqual(actual.confirmed, state.confirmed)
                XCTAssertEqual(actual.unconfirmed, state.unconfirmed)
                await pool.close()
            }
        }
    }

    func testConflictingHistoryHeightsStillRejectWholeBatchForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            for heights: (Int64, Int64) in [(100, 101), (100, 0), (0, -1)] {
                let state = BitcoinAddressState(confirmed: 0, unconfirmed: 0,
                    history: [.init(txid: a, height: heights.0), .init(txid: a, height: heights.1)], unspent: [])
                let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in StubTransport(.state(state), network: network) }
                do { _ = try await pool.query(scriptHashes: [a]); XCTFail("Conflicting heights accepted") }
                catch { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
                await pool.close()
            }
        }
    }

    func testDuplicateUnspentOutputsStillFailEvenWhenInflatedBalanceMatches() async throws {
        for network in UTXONetwork.allCases {
            let output = BitcoinUnspent(txid: a, vout: 0, value: 50_000, height: 100)
            let state = BitcoinAddressState(confirmed: 100_000, unconfirmed: 0,
                history: [.init(txid: a, height: 100)], unspent: [output, output])
            let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in StubTransport(.state(state), network: network) }
            do { _ = try await pool.query(scriptHashes: [a]); XCTFail("Duplicate spendable output accepted") }
            catch { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
            await pool.close()
        }
    }

    func testDifferentMempoolFeesAreNotTreatedAsIdenticalRecords() async throws {
        let rows: JSONValue = .array([
            .object(["id": .integer(0), "result": .object(["confirmed": .integer(0), "unconfirmed": .integer(0)])]),
            .object(["id": .integer(1), "result": .array([100, 200].map { fee in
                .object(["tx_hash": .string(a), "height": .integer(0), "fee": .integer(Int64(fee))])
            })]),
            .object(["id": .integer(2), "result": .array([])])
        ])
        let response = try JSONEncoder().encode(rows)
        let pool = ElectrumPool(servers: [.init("fixture")], network: .dogecoin) { _ in HistoryResponseWire(response: response) }
        do { _ = try await pool.query(scriptHashes: [a]); XCTFail("Conflicting records accepted") }
        catch { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
        await pool.close()
    }
}

final class ElectrumHistoryLiveTests: XCTestCase, @unchecked Sendable {
    func testPublicUsedDogecoinAddressesAgreeAcrossEveryConfiguredPeer() async throws {
        guard ProcessInfo.processInfo.environment["OATH_DOGECOIN_HISTORY_LIVE"] == "1" else {
            throw XCTSkip("Opt-in read-only public test-vector history; no app wallets, signing or broadcast")
        }
        let fixture = try DogecoinVectors.load()
        let wallet = try DogecoinKeys.extended(fixture.accountPublic)
        let branch = try XCTUnwrap(wallet.branches.first { $0.change == 0 })
        let addresses = try BitcoinKeys.addresses(branch: branch, range: 0..<2)
        var reference: [BitcoinAddressState]?
        for server in UTXONetwork.dogecoin.servers {
            let pool = ElectrumPool(servers: [server], network: .dogecoin)
            let state = try await pool.query(scriptHashes: addresses.map(\.scriptHash))
            XCTAssertTrue(state.allSatisfy { !$0.history.isEmpty })
            XCTAssertTrue(state.allSatisfy { Set($0.history.map(\.txid)).count == $0.history.count })
            if let reference { XCTAssertEqual(state, reference, server.host) }
            else { reference = state }
            let ids = Array(Set(state.flatMap { $0.history.prefix(2).map(\.txid) })).sorted()
            let raw = try await pool.transactions(txids: ids)
            XCTAssertEqual(Set(raw.keys), Set(ids))
            for id in ids { XCTAssertEqual(try BitcoinTransactions.txid(XCTUnwrap(raw[id]), network: .dogecoin), id) }
            let attempts = await pool.diagnostics()
            XCTAssertTrue(attempts.allSatisfy { $0.error == nil }, server.host)
            print("LIVE DOGE HISTORY \(server.host): \(state.count) used addresses, \(state.map { $0.history.count }) unique history entries; \(raw.count) transactions hash-verified; no peer fallback")
            await pool.close()
        }
    }
}
