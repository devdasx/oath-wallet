import Foundation
import OathDiagnostics

enum ElectrumSnapshot {
    private struct Candidate: Sendable {
        let host: String
        let pool: ElectrumPool
        let tip: BitcoinChainTip
    }
    private enum Probe: Sendable { case ready(Candidate), failed(BitcoinError), selectionDeadline }
    private enum Read<Value: Sendable>: Sendable {
        case stable(Value, BitcoinChainTip)
        case advanced(BitcoinChainTip)
        case failed(any Error)
    }

    static func read<Value: Sendable>(_ peers: [(String, ElectrumPool)], network: UTXONetwork,
        deferredHosts: Set<String> = [],
        operation: @escaping @Sendable (ElectrumPool) async throws -> Value
    ) async throws -> (value: Value, tip: BitcoinChainTip) {
        do {
            var last: any Error = BitcoinError.unavailable
            var highestObserved: Int64 = 0
            for attempt in 0..<3 {
                try Task.checkCancellation()
                if attempt > 0 {
                    try await Task.sleep(for: .milliseconds(200 * attempt))
                    for (_, pool) in peers { await pool.retrySnapshotConnection() }
                }
                let preferred = peers.filter { !deferredHosts.contains($0.0) }
                // Defer recently failed peers only while healthy alternatives
                // can complete a snapshot. If those fail, retry every peer in
                // the next existing round without resetting the observed tip.
                let probing = attempt == 0 && !preferred.isEmpty ? preferred : peers
                let candidates = try await withThrowingTaskGroup(of: Probe.self) { group in
                    defer { group.cancelAll() }
                    for (host, pool) in probing {
                        group.addTask {
                            do {
                                let tip = try await probe(pool)
                                try Task.checkCancellation()
                                await pool.recordSnapshotProbeResult(nil)
                                return .ready(Candidate(host: host, pool: pool, tip: tip))
                            }
                            catch {
                                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                let failure = (error as? BitcoinError) ?? .invalidResponse
                                await pool.recordSnapshotProbeResult(failure)
                                OathDiagnostics.record(error, component: "electrum", operation: "snapshot_probe",
                                    context: ["chain": network.rawValue, "host": host])
                                return .failed(failure)
                            }
                        }
                    }
                    var values: [Candidate] = []
                    var remaining = probing.count
                    // Give responsive peers a short opportunity to report a
                    // newer tip. An unanswered server is not a freshness vote:
                    // it must not hold every healthy scan for its 5s timeout.
                    // No healthy response still uses the normal probe timeout.
                    while remaining > 0, let result = try await group.next() {
                        try Task.checkCancellation()
                        switch result {
                        case .ready(let candidate):
                            remaining -= 1
                            if values.isEmpty {
                                group.addTask {
                                    try await Task.sleep(for: .milliseconds(250))
                                    return .selectionDeadline
                                }
                            }
                            values.append(candidate)
                        case .failed(let error):
                            remaining -= 1
                            if error != .unavailable { last = error }
                        case .selectionDeadline: return values
                        }
                    }
                    return values
                }
                guard let height = candidates.map(\.tip.height).max() else { continue }
                highestObserved = max(highestObserved, height)
                // A fast header response does not imply fast discovery/funding
                // reads. Race complete, isolated snapshots at the freshest tip;
                // never put healthy peers behind another peer's 12s timeout.
                // Each result still uses one peer for its start/data/end reads.
                let snapshot = try await withThrowingTaskGroup(of: Read<Value>.self) { group -> (Value, BitcoinChainTip)? in
                    defer { group.cancelAll() }
                    for candidate in candidates where candidate.tip.height == highestObserved {
                        group.addTask {
                            do {
                                let value = try await operation(candidate.pool)
                                let end = try await candidate.pool.chainTip()
                                try Task.checkCancellation()
                                return end == candidate.tip ? .stable(value, end) : .advanced(end)
                            } catch {
                                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                                OathDiagnostics.record(error, component: "electrum", operation: "snapshot_retry",
                                    context: ["chain": network.rawValue, "host": candidate.host])
                                return .failed(error)
                            }
                        }
                    }
                    for try await result in group {
                        try Task.checkCancellation()
                        switch result {
                        case .stable(let value, let tip):
                            if tip.height == highestObserved { return (value, tip) }
                        case .advanced(let tip):
                            // Normal block/reorg: discard this entire result.
                            // Never accept an older result after observing a new tip.
                            highestObserved = max(highestObserved, tip.height)
                            last = BitcoinError.inconsistentSnapshot
                        case .failed(let error): last = error
                        }
                    }
                    return nil
                }
                if let snapshot {
                    for (_, pool) in peers { await pool.close() }
                    return snapshot
                }
            }
            throw last
        } catch {
            OathDiagnostics.record(error, component: "electrum", operation: "snapshot", context: ["chain": network.rawValue])
            for (_, pool) in peers { await pool.close() }
            throw error
        }
    }

    private static func probe(_ pool: ElectrumPool) async throws -> BitcoinChainTip {
        try await withThrowingTaskGroup(of: BitcoinChainTip.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await pool.chainTip() }
            group.addTask { try await Task.sleep(for: .seconds(5)); throw BitcoinError.timeout }
            return try await group.next()!
        }
    }
}
