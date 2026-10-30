import Foundation
import XCTest
import OathDiagnostics
@testable import OathBitcoin

private actor SnapshotWire: ElectrumTransport {
    let network: UTXONetwork
    let height: Int64
    let changes: Int
    let rejectReads: Bool
    var headers = 0
    init(network: UTXONetwork, height: Int64, changes: Int = 0, rejectReads: Bool = false) {
        self.network = network; self.height = height; self.changes = changes; self.rejectReads = rejectReads
    }
    nonisolated func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if rejectReads && requests.contains(where: { $0["method"]?.string?.contains("scripthash") == true }) { throw BitcoinError.timeout }
        let raw = try await StubTransport(.empty, network: network).exchange(data, timeout: timeout)
        var rows = try JSONDecoder().decode(JSONValue.self, from: raw).array!
        for request in requests where request["method"]?.string == "blockchain.headers.subscribe" {
            headers += 1
            // Handshake + probe are stable; subsequent changes model a block
            // arriving during discovery, including repeated advancing tips.
            let delta = min(max(0, headers - 2), changes)
            let tip = height + Int64(delta)
            let id = request["id"]!
            let index = rows.firstIndex { $0["id"] == id }!
            rows[index] = .object(["id": id, "result": .object(["height": .integer(tip),
                "hex": .string(String(format: "%016llx", tip) + String(repeating: "0", count: 144))])])
        }
        return try JSONEncoder().encode(JSONValue.array(rows))
    }
}
private actor SnapshotCount { var value = 0; func add() { value += 1 } }

private struct SlowProbeWire: ElectrumTransport {
    let network: UTXONetwork
    let stalled: Bool
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        if stalled { try await Task.sleep(for: .seconds(2)); throw BitcoinError.timeout }
        return try await StubTransport(.empty, network: network).exchange(data, timeout: timeout)
    }
}

private final class SnapshotReconnectFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    let network: UTXONetwork
    let failure: BitcoinError
    let duringProbe: Bool
    let failedConnections: Int
    init(network: UTXONetwork, failure: BitcoinError, duringProbe: Bool, failedConnections: Int = 1) {
        self.network = network; self.failure = failure; self.duringProbe = duringProbe
        self.failedConnections = failedConnections
    }
    var connections: Int { lock.withLock { count } }
    func make() -> any ElectrumTransport {
        let failing = lock.withLock { count += 1; return count <= failedConnections }
        return SnapshotReconnectWire(network: network, failure: failing ? failure : nil, duringProbe: duringProbe)
    }
}
private struct SnapshotReconnectWire: ElectrumTransport {
    let network: UTXONetwork
    let failure: BitcoinError?
    let duringProbe: Bool
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        let reading = requests.contains { $0["method"]?.string?.contains("scripthash") == true }
        if let failure, duringProbe || reading { throw failure }
        if reading { XCTAssertGreaterThanOrEqual(timeout, 12, "A tip probe's short deadline must not truncate HD discovery") }
        return try await StubTransport(.empty, network: network).exchange(data, timeout: timeout)
    }
}
private final class SnapshotOutcomeFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let outcomes: [BitcoinError?]
    init(_ outcomes: [BitcoinError?]) { self.outcomes = outcomes }
    var connections: Int { lock.withLock { count } }
    func make() -> any ElectrumTransport {
        let error = lock.withLock { let index = min(count, outcomes.count - 1); count += 1; return outcomes[index] }
        return SnapshotReconnectWire(network: .bitcoin, failure: error, duringProbe: true)
    }
}
private final class SnapshotSilentFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let recoverAfter: Int?
    init(recoverAfter: Int? = nil) { self.recoverAfter = recoverAfter }
    var connections: Int { lock.withLock { count } }
    func make() -> any ElectrumTransport {
        let recovered = lock.withLock {
            count += 1
            return recoverAfter.map { count > $0 } ?? false
        }
        return recovered ? StubTransport(.empty) : SnapshotSilentWire()
    }
}
private struct SnapshotSilentWire: ElectrumTransport {
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        // The coordinator's five-second probe deadline cancels this exchange
        // before the transport's own timeout can record a failed request.
        try await Task.sleep(for: .seconds(60))
        throw BitcoinError.timeout
    }
}
private struct SmallBatchSnapshotWire: ElectrumTransport {
    func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        guard requests.count <= 12 else { throw BitcoinError.disconnected }
        return try await StubTransport(.empty).exchange(data, timeout: timeout)
    }
}

private actor DelayedSnapshotWire: ElectrumTransport {
    let base: SnapshotWire
    let slowScan: Bool
    let scanDelay: Duration
    private var exchanges = 0
    init(network: UTXONetwork, slowScan: Bool, changes: Int = 0, scanDelay: Duration = .zero) {
        base = SnapshotWire(network: network, height: 900_002, changes: changes)
        self.slowScan = slowScan
        self.scanDelay = scanDelay
    }
    nonisolated func close() {}
    func exchange(_ data: Data, timeout: TimeInterval) async throws -> Data {
        exchanges += 1
        // The unhealthy peer wins the tip probe, then hangs on discovery.
        // A healthy peer must not wait behind its full request timeout.
        if exchanges == 1 && !slowScan { try await Task.sleep(for: .milliseconds(40)) }
        let requests = try JSONDecoder().decode(JSONValue.self, from: data).array!
        if requests.contains(where: { $0["method"]?.string?.contains("scripthash") == true }) {
            if slowScan {
                try await Task.sleep(for: .seconds(2))
                throw BitcoinError.timeout
            }
            try await Task.sleep(for: scanDelay)
        }
        return try await base.exchange(data, timeout: timeout)
    }
}

final class ElectrumSnapshotTests: XCTestCase, @unchecked Sendable {
    func testCancelledProbeRaceDoesNotCreateFalseBackoff() async throws {
        let silent = SnapshotSilentFactory()
        let healthy = SnapshotOutcomeFactory([nil])
        let pool = ElectrumPool(servers: [.init("silent"), .init("healthy")]) { server in
            server.host == "silent" ? silent.make() : healthy.make()
        }
        for _ in 0..<3 {
            let next = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(next.value.count, 1)
        }
        XCTAssertEqual(silent.connections, 3, "Race cancellation before the deadline is not an observed provider failure")
        await pool.close()
    }

    func testSuccessfulProbeClearsEarlierCoordinatorTimeout() async throws {
        let recovered = SnapshotSilentFactory(recoverAfter: 1)
        let other = SnapshotOutcomeFactory([.timeout, nil])
        let pool = ElectrumPool(servers: [.init("recovered"), .init("other")]) { server in
            server.host == "recovered" ? recovered.make() : other.make()
        }
        for _ in 0..<2 {
            let next = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(next.value.count, 1)
            XCTAssertEqual(next.tip.height, 900_000)
        }
        XCTAssertEqual(recovered.connections, 3, "A verified successful probe must restore eligibility immediately")
        await pool.close()
    }

    func testProbeDeadlineBackoffSurvivesCancelledRetryAndSubsequentRefreshes() async throws {
        let silent = SnapshotSilentFactory()
        let recovered = SnapshotOutcomeFactory([.timeout, nil])
        let pool = ElectrumPool(servers: [.init("silent"), .init("recovered")]) { server in
            server.host == "silent" ? silent.make() : recovered.make()
        }
        let first = try await pool.withStableSnapshot {
            try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
        }
        XCTAssertEqual(first.value.count, 1)
        XCTAssertEqual(first.tip.height, 900_000)
        XCTAssertEqual(silent.connections, 2, "The first deadline expires; the next probe is cancelled after recovery")
        for _ in 0..<2 {
            let next = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(next.value.count, 1)
            XCTAssertEqual(next.tip.height, 900_000)
        }
        XCTAssertEqual(silent.connections, 2, "A coordinator timeout must retain backoff even when a later probe is cancelled")
        XCTAssertEqual(recovered.connections, 4)
        await pool.close()
    }

    func testDeferredPeerCanRecoverIfPreferredPeerFailsWithoutLosingSnapshotChecks() async throws {
        for failure in [BitcoinError.disconnected, .batchUnsupported, .wrongNetwork] {
            let recovered = SnapshotOutcomeFactory([failure, nil])
            let failing = SnapshotOutcomeFactory([nil, .timeout])
            let pool = ElectrumPool(servers: [.init("recovered"), .init("failing")]) { server in
                server.host == "recovered" ? recovered.make() : failing.make()
            }
            for _ in 0..<2 {
                let value = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating: "0", count: 64)]) }
                XCTAssertEqual(value.value.count, 1)
                XCTAssertEqual(value.tip.height, 900_000)
            }
            XCTAssertEqual(recovered.connections, 2, "Backoff cannot turn into permanent exclusion when other peers fail")
            await pool.close()
        }
    }

    func testExpiredSnapshotBackoffRetriesPeer() async throws {
        let recovered = SnapshotOutcomeFactory([.disconnected, nil]), healthy = SnapshotOutcomeFactory([nil])
        let pool = ElectrumPool(servers: [.init("recovered"), .init("healthy")], snapshotBackoffLifetime: 0.02) { server in
            server.host == "recovered" ? recovered.make() : healthy.make()
        }
        _ = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating: "0", count: 64)]) }
        try await Task.sleep(for: .milliseconds(40))
        _ = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating: "0", count: 64)]) }
        XCTAssertEqual(recovered.connections, 2)
        await pool.close()
    }

    func testSuccessfulRefreshRetainsFailedPeerBackoffAcrossSnapshots() async throws {
        for failure in [BitcoinError.timeout, .disconnected, .batchUnsupported, .wrongNetwork] {
            let failed = SnapshotReconnectFactory(network: .bitcoin, failure: failure, duringProbe: true, failedConnections: 100)
            let healthy = SnapshotReconnectFactory(network: .bitcoin, failure: .timeout, duringProbe: true, failedConnections: 0)
            let pool = ElectrumPool(servers: [.init("failed"), .init("healthy")]) { server in
                server.host == "failed" ? failed.make() : healthy.make()
            }
            for _ in 0..<5 {
                let value = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating: "0", count: 64)]) }
                XCTAssertEqual(value.value.count, 1)
            }
            XCTAssertEqual(failed.connections, 1, "New snapshot pools must retain the failed peer's backoff: \(failure)")
            XCTAssertEqual(healthy.connections, 5)
            await pool.close()
        }
    }

    func testAllPeersRecoverAfterTwoSimultaneousTimeoutRoundsForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let factories = (0..<3).map { _ in
                SnapshotReconnectFactory(network: network, failure: .timeout, duringProbe: true, failedConnections: 2)
            }
            let servers = (0..<3).map { ElectrumServer("outage-\($0)") }
            let pool = ElectrumPool(servers: servers, network: network) { server in
                factories[servers.firstIndex(of: server)!].make()
            }
            let result = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(result.tip.height, 900_000)
            XCTAssertEqual(result.value.count, 1)
            XCTAssertEqual(factories.map(\.connections), [3, 3, 3])
            await pool.close()
        }
    }

    func testAllPeerOutageIsBoundedAndNextRefreshCanRecoverForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let factories = (0..<3).map { _ in
                SnapshotReconnectFactory(network: network, failure: .timeout, duringProbe: true, failedConnections: 3)
            }
            let servers = (0..<3).map { ElectrumServer("outage-\($0)") }
            let pool = ElectrumPool(servers: servers, network: network) { server in
                factories[servers.firstIndex(of: server)!].make()
            }
            let reads = SnapshotCount()
            do {
                _ = try await pool.withStableSnapshot { _ in await reads.add(); return 0 }
                XCTFail("An all-peer outage must not publish an empty snapshot")
            } catch { XCTAssertEqual(error as? BitcoinError, .timeout) }
            let attemptedReads = await reads.value
            XCTAssertEqual(attemptedReads, 0)
            XCTAssertEqual(factories.map(\.connections), [3, 3, 3], "Outage retries must be bounded")

            let recovered = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(recovered.value.count, 1)
            XCTAssertEqual(recovered.tip.height, 900_000)
            XCTAssertEqual(factories.map(\.connections), [4, 4, 4])
            await pool.close()
        }
    }

    func testReportedDisconnectAndStalledProbeCannotBlockHealthySnapshot() async throws {
        for network in UTXONetwork.allCases {
            let pool = ElectrumPool(servers: [.init("disconnected"), .init("stalled"), .init("healthy")], network: network) { server in
                if server.host == "disconnected" {
                    return SnapshotReconnectWire(network: network, failure: .disconnected, duringProbe: true)
                }
                return SlowProbeWire(network: network, stalled: server.host == "stalled")
            }
            let start = ContinuousClock.now
            let result = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(result.tip.height, 900_000)
            XCTAssertEqual(result.value.count, 1)
            XCTAssertLessThan(start.duration(to: .now), .seconds(1))
            await pool.close()
        }
    }

    func testPersistentProbeDisconnectRemainsFailureForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let pool = ElectrumPool(servers: [.init("disconnected")], network: network) { _ in
                SnapshotReconnectWire(network: network, failure: .disconnected, duringProbe: true)
            }
            let start = ContinuousClock.now
            do {
                _ = try await pool.withStableSnapshot { _ in true }
                XCTFail("A provider outage must not become a successful empty wallet")
            } catch { XCTAssertEqual(error as? BitcoinError, .disconnected) }
            XCTAssertLessThan(start.duration(to: .now), .seconds(2))
            await pool.close()
        }
    }

    func testStalledProbeDoesNotHoldHealthyDiscoveryForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let pool = ElectrumPool(servers: [.init("stalled-probe"), .init("healthy")], network: network) {
                SlowProbeWire(network: network, stalled: $0.host == "stalled-probe")
            }
            let start = ContinuousClock.now
            let result = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(result.value.count, 1)
            XCTAssertLessThan(start.duration(to: .now), .seconds(1), "An unanswered peer must not delay a verified healthy snapshot")
            print("PROBE REGRESSION \(network.rawValue): \(start.duration(to: .now))")
        }
    }

    func testStalledCurrentPeerDoesNotDelayHealthySnapshotForEveryChain() async throws {
        for network in UTXONetwork.allCases {
            let pool = ElectrumPool(servers: [.init("fast-probe-slow-scan"), .init("healthy")], network: network) {
                DelayedSnapshotWire(network: network, slowScan: $0.host == "fast-probe-slow-scan")
            }
            let start = ContinuousClock.now
            let result = try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
            }
            XCTAssertEqual(result.tip.height, 900_002)
            XCTAssertEqual(result.value.count, 1)
            XCTAssertLessThan(start.duration(to: .now), .seconds(1), "A healthy scan must not queue behind a stalled peer")
            print("STALL REGRESSION \(network.rawValue): \(start.duration(to: .now))")
        }
    }

    func testNewerTipDuringRaceDiscardsOlderConcurrentSnapshot() async throws {
        let pool = ElectrumPool(servers: [.init("advancing"), .init("stable-but-old")]) {
            DelayedSnapshotWire(network: .bitcoin, slowScan: false,
                changes: $0.host == "advancing" ? 1 : 0,
                scanDelay: $0.host == "advancing" ? .zero : .milliseconds(150))
        }
        let count = SnapshotCount()
        let result = try await pool.withStableSnapshot {
            await count.add()
            return try await $0.query(scriptHashes: [String(repeating: "0", count: 64)])
        }
        XCTAssertEqual(result.tip.height, 900_003)
        let attempts = await count.value
        XCTAssertEqual(attempts, 3, "Both initial scans plus a new scan at the advancing peer's new tip")
    }

    func testLiveFeesAndFundingDiscoveryForAllChains() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SNAPSHOT_LIVE"] == "1" else {
            throw XCTSkip("Read-only public fee APIs and synthetic wallet snapshots; never signs or broadcasts")
        }
        let fees = UTXOFeeProvider()
        for network in UTXONetwork.allCases {
            let start = ContinuousClock.now
            let descriptor = try network.wallet(seed: Data(0..<32))
            let pool = ElectrumPool(network: network)
            async let rate = fees.rate(for: network)
            let snapshot = try await pool.withStableSnapshot { peer in
                let scan = try await BitcoinDiscovery(query: peer, maximumIndex: 100).scan(descriptor)
                try scan.validate(wallet: descriptor, requiredThrough: [:])
                let txids = Array(Set(scan.addresses.flatMap { $0.state.unspent.map(\.txid) }))
                let transactions = try await peer.transactions(txids: txids)
                for address in scan.addresses {
                    for output in address.state.unspent {
                        guard let raw = transactions[output.txid],
                              try BitcoinTransactions.validates(raw, txid: output.txid, vout: output.vout,
                                  value: output.value, script: address.address.script, network: network) else {
                            throw BitcoinError.invalidResponse
                        }
                    }
                }
                return scan
            }
            let fee = try await rate
            XCTAssertTrue(network.sendFeeRates.contains(fee))
            XCTAssertFalse(snapshot.value.addresses.isEmpty)
            print("LIVE FEE + DISCOVERY \(network.rawValue): atomic/kVB=\(fee), addresses=\(snapshot.value.addresses.count), duration=\(start.duration(to: .now))")
            await pool.close()
        }
    }
    func testSnapshotReconnectsAfterProbeOrScanTransportFailureForAllChains() async throws {
        for network in UTXONetwork.allCases {
            for failure in [BitcoinError.timeout, .disconnected] {
                for duringProbe in [true, false] {
                    let factory = SnapshotReconnectFactory(network: network, failure: failure, duringProbe: duringProbe)
                    let pool = ElectrumPool(servers: [.init("fixture")], network: network) { _ in factory.make() }
                    let value = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating:"0",count:64)]) }
                    XCTAssertEqual(value.value.count, 1); XCTAssertEqual(factory.connections, 2)
                }
            }
        }
    }
    func testSnapshotNeverRetriesTLSOrWrongNetworkAsTransient() async throws {
        for failure in [BitcoinError.tls, .wrongNetwork, .batchUnsupported] {
            let factory = SnapshotReconnectFactory(network:.bitcoin, failure:failure, duringProbe:true)
            let pool = ElectrumPool(servers:[.init("fixture")]) { _ in factory.make() }
            do { _ = try await pool.withStableSnapshot { _ in 0 }; XCTFail("Unsafe peer retried") }
            catch { XCTAssertEqual(error as? BitcoinError, failure) }
            XCTAssertEqual(factory.connections, 1)
        }
    }
    func testBlockstreamBatchCapCompletesAllHDReceiveAndChangeBranches() async throws {
        let server = try XCTUnwrap(ElectrumServer.publicMainnet.first { $0.host == "electrum.blockstream.info" })
        let pool = ElectrumPool(servers:[server]) { _ in SmallBatchSnapshotWire() }
        let wallet = try UTXONetwork.bitcoin.wallet(seed:Data(0..<32))
        let value = try await pool.withStableSnapshot { try await BitcoinDiscovery(query:$0).scan(wallet) }
        try value.value.validate(wallet:wallet, requiredThrough:[:])
        XCTAssertEqual(value.value.addresses.count, 160)
    }
    func testLiveBlockstreamHDScan() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SNAPSHOT_LIVE"] == "1" else { throw XCTSkip("Read-only synthetic wallet discovery") }
        let server = try XCTUnwrap(ElectrumServer.publicMainnet.first { $0.host == "electrum.blockstream.info" })
        let pool = ElectrumPool(servers:[server])
        let wallet = try UTXONetwork.bitcoin.wallet(seed:Data(0..<32))
        let started = ContinuousClock.now
        let value = try await pool.withStableSnapshot { try await BitcoinDiscovery(query:$0).scan(wallet) }
        try value.value.validate(wallet:wallet, requiredThrough:[:])
        print("LIVE Blockstream HD snapshot: \(value.value.addresses.count) addresses, \(started.duration(to:.now))")
    }
    func testLaggingPeerCannotMixHeightsAcrossScanForAnyChain() async throws {
        for network in UTXONetwork.allCases {
            let pool = ElectrumPool(servers: [.init("lagging"), .init("current")], network: network) {
                SnapshotWire(network: network, height: $0.host == "lagging" ? 900_000 : 900_002)
            }
            let snapshot = try await pool.withStableSnapshot { peer in
                let before = try await peer.chainTip()
                let states = try await peer.query(scriptHashes: [String(repeating: "0", count: 64)])
                let after = try await peer.chainTip()
                XCTAssertEqual(before, after); XCTAssertEqual(before.height, 900_002)
                return states
            }
            XCTAssertEqual(snapshot.tip.height, 900_002); XCTAssertEqual(snapshot.value.count, 1)
        }
    }
    func testNewBlockRetriesEntireOperationAndNeverCommitsOldResult() async throws {
        let count = SnapshotCount()
        let pool = ElectrumPool(servers: [.init("advancing")]) { _ in SnapshotWire(network: .bitcoin, height: 900_000, changes: 1) }
        let result = try await pool.withStableSnapshot { _ in await count.add(); return "snapshot" }
        let attempts = await count.value
        XCTAssertEqual(attempts, 2); XCTAssertEqual(result.tip.height, 900_001)
    }
    func testUnstableNetworkIsBoundedAndCancellationIsPreserved() async throws {
        let count = SnapshotCount()
        let unstable = ElectrumPool(servers: [.init("advancing")]) { _ in SnapshotWire(network: .bitcoin, height: 900_000, changes: 100) }
        do { _ = try await unstable.withStableSnapshot { _ in await count.add(); return 0 }; XCTFail("Unstable snapshot accepted") }
        catch { XCTAssertEqual(error as? BitcoinError, .inconsistentSnapshot) }
        let attempts = await count.value; XCTAssertEqual(attempts, 3)
        let pool = ElectrumPool(servers: [.init("cancel")]) { _ in SnapshotWire(network: .bitcoin, height: 900_000) }
        do { _ = try await pool.withStableSnapshot { _ -> Int in throw CancellationError() }; XCTFail() }
        catch is CancellationError {}
    }
    func testFailedCurrentPeerUsesOtherCurrentPeerNotLaggingData() async throws {
        let pool = ElectrumPool(servers: [.init("lagging"), .init("broken"), .init("healthy")]) {
            SnapshotWire(network: .bitcoin, height: $0.host == "lagging" ? 900_000 : 900_002, rejectReads: $0.host == "broken")
        }
        let snapshot = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating: "0", count: 64)]) }
        XCTAssertEqual(snapshot.tip.height, 900_002); XCTAssertEqual(snapshot.value.first?.confirmed, 0)
    }
    func testFailedFreshPeerCannotFallBackToPreviouslyObservedOlderTip() async throws {
        let pool = ElectrumPool(servers: [.init("lagging"), .init("broken")]) {
            SnapshotWire(network: .bitcoin, height: $0.host == "lagging" ? 900_000 : 900_002, rejectReads: $0.host == "broken")
        }
        do {
            _ = try await pool.withStableSnapshot { try await $0.query(scriptHashes: [String(repeating: "0", count: 64)]) }
            XCTFail("A stale snapshot replaced the unavailable fresh snapshot")
        } catch { XCTAssertEqual(error as? BitcoinError, .timeout) }
    }
    func testLiveAllFamilySnapshotsWithIndependentPeers() async throws {
        guard ProcessInfo.processInfo.environment["OATH_SNAPSHOT_LIVE"] == "1" else { throw XCTSkip("Read-only Bitcoin-family snapshots, public synthetic descriptor") }
        for network in UTXONetwork.allCases {
            let started = ContinuousClock.now
            let pool = ElectrumPool(network: network)
            // Public deterministic fixture; no user wallet material is accessed.
            let descriptor = try network.wallet(seed: Data(0..<32))
            let snapshot = try await pool.withStableSnapshot { peer in
                let scan = try await BitcoinDiscovery(query: peer, maximumIndex: 100).scan(descriptor)
                try scan.validate(wallet: descriptor, requiredThrough: [:]); return scan
            }
            XCTAssertFalse(snapshot.value.addresses.isEmpty)
            XCTAssertTrue(snapshot.value.addresses.allSatisfy { $0.state.history.allSatisfy { $0.height <= snapshot.tip.height } })
            print("LIVE \(network.rawValue) stable snapshot: \(snapshot.value.addresses.count) addresses checked at height \(snapshot.tip.height), \(started.duration(to:.now))")
            await pool.close()
        }
    }
}

private actor SnapshotDeadlineReports: DiagnosticTransport {
    var events: [DiagnosticEvent] = []
    func upload(_ events: [DiagnosticEvent]) async throws { self.events += events }
}

final class ElectrumProbeDeadlineDiagnosticsTests: XCTestCase, @unchecked Sendable {
    // Run in its own process: the shared diagnostic outbox configures only once.
    func testDeadlineRetainsPeerBackoffWhileAvailabilityAndCancelledRetryStayQuiet() async throws {
        let reports = SnapshotDeadlineReports()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        OathDiagnostics.configure(file: directory.appendingPathComponent("events.json"), transport: reports)
        let silent = SnapshotSilentFactory()
        let recovered = SnapshotOutcomeFactory([.timeout, nil])
        let pool = ElectrumPool(servers: [.init("silent"), .init("recovered")]) { server in
            server.host == "silent" ? silent.make() : recovered.make()
        }
        let operation = UUID()
        _ = try await OathDiagnostics.$operationID.withValue(operation) {
            try await pool.withStableSnapshot {
                try await $0.query(scriptHashes: [String(repeating: "1", count: 64)])
            }
        }
        // Shared policy excludes availability timeouts before admission. The
        // pool must still remember the deadline and avoid reopening that peer.
        _ = try await pool.withStableSnapshot {
            try await $0.query(scriptHashes: [String(repeating: "1", count: 64)])
        }
        let events = await reports.events
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(silent.connections, 2)
        await pool.close()
    }
}
