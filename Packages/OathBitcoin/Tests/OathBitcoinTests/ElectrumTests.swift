import Foundation
import XCTest
@testable import OathBitcoin

final class ElectrumTests: XCTestCase, @unchecked Sendable {
    func testUnorderedBatchAndEmptySuccess() throws {
        let values = try ElectrumBatch.decode(Data(#"[{"id":2,"result":[]},{"id":1,"result":{"confirmed":0,"unconfirmed":0}}]"#.utf8), ids: [1,2])
        XCTAssertEqual(values[2], .array([])); XCTAssertEqual(values[1]?["confirmed"], .integer(0))
    }
    func testMalformedIncompleteAndUnsupportedBatchesFail() {
        for json in [#"{"id":1,"result":[]}"#, #"[{"id":1,"result":[]}]"#,
                     #"[{"id":1,"result":[]},{"id":1,"result":[]}]"#,
                     #"[{"id":1,"result":[]},{"id":3,"result":[]}]"#,
                     #"[{"id":1},{"id":2,"result":[]}]"#,
                     #"[{"id":1,"error":{"code":-32600}},{"id":2,"result":[]}]"#,
                     #"[{"id":1,"error":{"code":1}},{"id":2,"result":[]}]"#] {
            XCTAssertThrowsError(try ElectrumBatch.decode(Data(json.utf8), ids: [1,2]))
        }
    }
    /// Explicit opt-in. Only public test-vector scripts are sent; never local
    /// app wallets, xpubs, mnemonics or private keys. Runs natively on macOS.
    func testLivePublicPeersBatchesAndFallback() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_LIVE"] == "1" else { throw XCTSkip("Live network check not requested") }
        let wallet = try BitcoinKeysTests.wallet()
        let hashes = try wallet.branches.filter { $0.change == 0 }.flatMap {
            try BitcoinKeys.addresses(branch: $0, range: 321..<322).map(\.scriptHash)
        }
        // A refused localhost port is followed by a real verified TLS peer.
        let pool = ElectrumPool(servers: [.init("localhost", port: 1), .init("electrum.jhoenicke.de"), .init("electrum.diynodes.com", port: 50022)], maximumConnections: 1)
        let result = try await pool.query(scriptHashes: hashes)
        XCTAssertEqual(result.count, 4)
        let attempts = await pool.diagnostics()
        XCTAssertTrue(attempts.contains { $0.error != nil })
        XCTAssertTrue(attempts.contains { $0.error == nil && $0.requestCount == 12 })
        await pool.close()
        for server in ElectrumServer.publicMainnet {
            let client = ElectrumPool(servers: [server])
            let values = try await client.query(scriptHashes: hashes)
            XCTAssertEqual(values.count, 4)
            await client.close()
        }
    }
    func testLiveLargeBatchAllTypesAndChangeBranches() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_LIVE"] == "1" else { throw XCTSkip("Live network check not requested") }
        let wallet = try BitcoinKeysTests.wallet()
        let addresses = try wallet.branches.flatMap { try BitcoinKeys.addresses(branch: $0, range: 1000..<1020) }
        XCTAssertEqual(addresses.count, 160)
        let pool = ElectrumPool()
        let result: [BitcoinAddressState]
        do { result = try await pool.query(scriptHashes: addresses.map(\.scriptHash)) }
        catch {
            let attempts = await pool.diagnostics()
            for attempt in attempts { print("Electrum peer: \(attempt.server), requests: \(attempt.requestCount), outcome: \(String(describing: attempt.error))") }
            throw error
        }
        XCTAssertEqual(result.count, 160)
        XCTAssertTrue(result.allSatisfy { $0.confirmed + $0.unconfirmed == $0.unspent.reduce(0) { $0 + $1.value } })
        let attempts = await pool.diagnostics()
        XCTAssertTrue(attempts.contains { $0.error == nil && $0.requestCount == 300 })
        XCTAssertTrue(attempts.contains { $0.error == nil && $0.requestCount == 180 })
        let tip = try await pool.chainTip(); XCTAssertGreaterThan(tip.height, 800_000)
        await pool.close()
    }

    func testLivePublishedAddressHistoryAndFundingTransactions() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_LIVE"] == "1" else { throw XCTSkip("Live network check not requested") }
        let wallet = try BitcoinKeysTests.wallet()
        let branch = wallet.branches.first { $0.type == .nativeSegwit && $0.change == 0 }!
        let address = try BitcoinKeys.addresses(branch: branch, range: 0..<1)[0]
        let pool = ElectrumPool()
        let states = try await pool.query(scriptHashes: [address.scriptHash])
        let state = try XCTUnwrap(states.first)
        XCTAssertFalse(state.history.isEmpty, "Published BIP84 address should have historical activity")
        let txids = Array(Set(state.unspent.map(\.txid) + state.history.prefix(2).map(\.txid)))
        let transactions = try await pool.transactions(txids: txids)
        XCTAssertEqual(transactions.count, txids.count)
        for utxo in state.unspent {
            XCTAssertTrue(try BitcoinTransactions.validates(transactions[utxo.txid]!, txid: utxo.txid, vout: utxo.vout, value: utxo.value, script: address.script))
        }
        await pool.close()
    }
}
