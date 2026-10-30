import Foundation
import XCTest
@testable import OathBitcoin

private final class TransactionSnapshotWireFactory: @unchecked Sendable {
    enum Reconnect: Sendable { case stable, advanced, wrongNetwork, unavailable }
    private let lock = NSLock()
    private var count = 0
    let failure: BitcoinError
    let reconnect: Reconnect
    let bytes: Data
    init(failure: BitcoinError = .timeout, reconnect: Reconnect = .stable, bytes: Data) {
        self.failure = failure; self.reconnect = reconnect; self.bytes = bytes
    }
    var connections: Int { lock.withLock { count } }
    func make() -> any ElectrumTransport {
        let index = lock.withLock { count += 1; return count }
        return TransactionSnapshotWire(index: index, failure: failure, reconnect: reconnect, bytes: bytes)
    }
}

private struct TransactionSnapshotWire: ElectrumTransport {
    let index: Int
    let failure: BitcoinError
    let reconnect: TransactionSnapshotWireFactory.Reconnect
    let bytes: Data
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if index > 1, reconnect == .unavailable { throw BitcoinError.timeout }
        if requests.contains(where: { $0["method"]?.string == "blockchain.transaction.get" }) {
            // The archive remains unavailable on Electrum. A later complete
            // snapshot after an advanced tip can use its now-healthy peer.
            if reconnect != .advanced || index == 1 { throw failure }
        }
        let stub = StubTransport(index > 1 && reconnect == .wrongNetwork ? .wrongNetwork : .empty)
        let data = try await stub.exchange(data, timeout: timeout)
        let rows = try JSONDecoder().decode(JSONValue.self, from: data).array!
        return try JSONEncoder().encode(JSONValue.array(rows.map { row in
            let request = requests.first { $0["id"] == row["id"] }!
            switch request["method"]?.string {
            case "blockchain.transaction.get":
                return .object(["id": row["id"]!, "result": .string(bytes.hex)])
            case "blockchain.headers.subscribe":
                let advanced = index > 1 && reconnect == .advanced
                return .object(["id": row["id"]!, "result": .object([
                    "height": .integer(advanced ? 900_001 : 900_000),
                    "hex": .string(String(repeating: advanced ? "1" : "0", count: 160))])])
            case "blockchain.block.header":
                var header = Data(repeating: 0, count: 80)
                header.replaceSubrange(68..<72, with: BitcoinWire.little(UInt32(1_700_000_000)))
                return .object(["id": row["id"]!, "result": .string(header.hex)])
            default: return row
            }
        }))
    }
}

private actor TransactionRecoveryCount {
    var value = 0
    func increment() { value += 1 }
}

final class ElectrumSnapshotTransactionRecoveryTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (hash: String, bytes: Data) {
        var raw = BitcoinWire.little(UInt32(2)) + Data([1]) + Data(repeating: 1, count: 32)
        raw += BitcoinWire.little(UInt32(0)) + Data([0]) + BitcoinWire.little(UInt32.max) + Data([1])
        raw += BitcoinWire.little(UInt64(100_000)) + BitcoinWire.vector(Data([0x51])) + BitcoinWire.little(UInt32(0))
        return (try BitcoinTransactions.txid(raw), raw)
    }

    func testVerifiedArchiveRecoveryCanFinishSamePeerSnapshotAndReadBlockTime() async throws {
        let fixture = try fixture()
        for failure in [BitcoinError.timeout, .disconnected] {
            let factory = TransactionSnapshotWireFactory(failure: failure, bytes: fixture.bytes)
            let reads = TransactionRecoveryCount()
            let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { ids in
                XCTAssertEqual(ids, [fixture.hash]); await reads.increment()
                return [fixture.hash: fixture.bytes]
            }, makeTransport: { _ in factory.make() })
            let snapshot = try await pool.withStableSnapshot { peer in
                let raw = try await peer.transactions(txids: [fixture.hash])
                let times = try await peer.blockTimes(heights: [900_000])
                return (raw, times)
            }
            XCTAssertEqual(snapshot.value.0[fixture.hash], fixture.bytes)
            XCTAssertEqual(snapshot.value.1[900_000], 1_700_000_000)
            XCTAssertEqual(snapshot.tip.height, 900_000)
            XCTAssertEqual(factory.connections, 2, "One fresh TLS handshake, without repeating the scan")
            let readCount = await reads.value
            XCTAssertEqual(readCount, 1)
            await pool.close()
        }
    }

    func testOrdinaryPoolRetainsOutageCooldownAfterArchiveRecovery() async throws {
        let fixture = try fixture()
        let factory = TransactionSnapshotWireFactory(bytes: fixture.bytes)
        let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { _ in
            [fixture.hash: fixture.bytes]
        }, makeTransport: { _ in factory.make() })
        _ = try await pool.transactions(txids: [fixture.hash])
        do { _ = try await pool.chainTip(); XCTFail("Shared pool must retain its outage budget") }
        catch { XCTAssertEqual(error as? BitcoinError, .unavailable) }
        XCTAssertEqual(factory.connections, 1)
        await pool.close()
    }

    func testRecoveredBytesCannotPublishSnapshotAcrossChangedTip() async throws {
        let fixture = try fixture()
        let factory = TransactionSnapshotWireFactory(reconnect: .advanced, bytes: fixture.bytes)
        let scans = TransactionRecoveryCount()
        let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { _ in
            [fixture.hash: fixture.bytes]
        }, makeTransport: { _ in factory.make() })
        let result = try await pool.withStableSnapshot { peer in
            await scans.increment()
            return try await peer.transactions(txids: [fixture.hash])
        }
        XCTAssertEqual(result.tip.height, 900_001)
        XCTAssertEqual(result.value[fixture.hash], fixture.bytes)
        let count = await scans.value
        XCTAssertEqual(count, 2, "A new tip requires repeating the entire read")
        XCTAssertEqual(factory.connections, 2)
        await pool.close()
    }

    func testReconnectMustAuthenticateNetworkAndPersistentOutageStaysBounded() async throws {
        let fixture = try fixture()
        for reconnect in [TransactionSnapshotWireFactory.Reconnect.wrongNetwork, .unavailable] {
            let factory = TransactionSnapshotWireFactory(reconnect: reconnect, bytes: fixture.bytes)
            let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { _ in
                [fixture.hash: fixture.bytes]
            }, makeTransport: { _ in factory.make() })
            do {
                _ = try await pool.withStableSnapshot { try await $0.transactions(txids: [fixture.hash]) }
                XCTFail("Archive data cannot replace a verified final header")
            } catch {
                XCTAssertEqual(error as? BitcoinError, reconnect == .wrongNetwork ? .wrongNetwork : .timeout)
            }
            XCTAssertEqual(factory.connections, reconnect == .wrongNetwork ? 2 : 4)
            await pool.close()
        }
    }

    func testInvalidArchiveCannotEnableSnapshotReconnect() async throws {
        let fixture = try fixture()
        for recovered in [[:], [fixture.hash: Data([0])]] {
            let factory = TransactionSnapshotWireFactory(bytes: fixture.bytes)
            let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { _ in recovered },
                makeTransport: { _ in factory.make() })
            do {
                _ = try await pool.withStableSnapshot { try await $0.transactions(txids: [fixture.hash]) }
                XCTFail("Missing or invalid bytes accepted")
            } catch {
                // Malformed bytes preserve the underlying BDK decoding error.
                // Missing bytes are rejected by the pool's exact-key-set guard.
                if recovered.isEmpty { XCTAssertEqual(error as? BitcoinError, .invalidResponse) }
                else { XCTAssertFalse(error is CancellationError) }
            }
            XCTAssertEqual(factory.connections, 3, "Only the existing three snapshot attempts are allowed")
            await pool.close()
        }
    }

    func testArchiveRecoveryDoesNotBypassProtocolCooldownOrPermitOtherRPCs() async throws {
        let fixture = try fixture()
        for failure in [BitcoinError.wrongNetwork, .invalidResponse, .batchUnsupported, .timeout] {
            let factory = TransactionSnapshotWireFactory(failure: failure, bytes: fixture.bytes)
            let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { _ in
                [fixture.hash: fixture.bytes]
            }, makeTransport: { _ in factory.make() })
            do {
                _ = try await pool.withStableSnapshot { peer in
                    _ = try await peer.transactions(txids: [fixture.hash])
                    if failure == .timeout {
                        // Only header verification may use the recovery permit.
                        _ = try await peer.query(scriptHashes: [String(repeating: "0", count: 64)])
                    }
                    return true
                }
                XCTFail("Cooldown bypassed")
            } catch { XCTAssertNotNil(error as? BitcoinError) }
            XCTAssertEqual(factory.connections, failure == .timeout ? 3 : 1)
            await pool.close()
        }
    }

    func testCancellationDuringArchiveRecoveryDoesNotReconnect() async throws {
        let fixture = try fixture(), reads = TransactionRecoveryCount()
        let factory = TransactionSnapshotWireFactory(bytes: fixture.bytes)
        let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: { _ in
            await reads.increment()
            try await Task.sleep(for: .seconds(30))
            return [fixture.hash: fixture.bytes]
        }, makeTransport: { _ in factory.make() })
        let task = Task { try await pool.withStableSnapshot { try await $0.transactions(txids: [fixture.hash]) } }
        for _ in 0..<100 {
            if await reads.value > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let count = await reads.value
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled snapshot returned") }
        catch is CancellationError { }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(factory.connections, 1)
        await pool.close()
    }

    func testLivePublicArchiveCanFinishSnapshotAfterInjectedElectrumTimeout() async throws {
        guard ProcessInfo.processInfo.environment["OATH_BITCOIN_SNAPSHOT_LIVE"] == "1" else {
            throw XCTSkip("Read-only public archive with an injected Electrum timeout")
        }
        let hash = "4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"
        let factory = TransactionSnapshotWireFactory(bytes: Data())
        let pool = ElectrumPool(servers: [.init("fixture")], transactionFallback: {
            try await BitcoinTransactionFallback.shared.transactions(txids: $0)
        }, makeTransport: { _ in factory.make() })
        let result = try await pool.withStableSnapshot { try await $0.transactions(txids: [hash]) }
        XCTAssertEqual(try BitcoinTransactions.txid(XCTUnwrap(result.value[hash])), hash)
        XCTAssertEqual(result.tip.height, 900_000, "Only the archive is live; the snapshot peer is a fixture")
        XCTAssertEqual(factory.connections, 2)
        await pool.close()
    }
}
