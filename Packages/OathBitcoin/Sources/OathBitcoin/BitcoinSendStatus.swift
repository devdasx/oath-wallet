import Foundation

/// A mined transaction spending the submitted transaction's inputs. A mempool
/// acknowledgement or a missing history row is never a terminal receipt.
public struct BitcoinSendConfirmation: Sendable {
    public let raw: Data
    public let height: Int64
    public let timestamp: Double
    public init(raw: Data, height: Int64, timestamp: Double) {
        self.raw = raw; self.height = height; self.timestamp = timestamp
    }
}

protocol BitcoinSendStatusReading: BitcoinAddressQuerying {
    func transactions(txids: [String]) async throws -> [String: Data]
    func blockTimes(heights: [Int64]) async throws -> [Int64: Double]
}
extension ElectrumPool: BitcoinSendStatusReading {}

public enum BitcoinSendStatus {
    public struct Payment: Sendable {
        public let raw: Data
        public let plan: BitcoinSendPlan
        public let txid: String

        public init(raw: Data, plan: BitcoinSendPlan) throws {
            guard !raw.isEmpty, raw.count <= 1_000_000 else { throw BitcoinSendError.changed }
            self.txid = try plan.recoveredTransactionID(raw)
            self.raw = raw
            self.plan = plan
        }
    }

    public static func confirmation(raw: Data, plan: BitcoinSendPlan, client: ElectrumPool) async throws -> BitcoinSendConfirmation? {
        try await confirmation(Payment(raw: raw, plan: plan), client: client)
    }

    public static func confirmation(_ payment: Payment, client: ElectrumPool) async throws -> BitcoinSendConfirmation? {
        guard payment.plan.network == .mainnet else { throw BitcoinError.wrongNetwork }
        let snapshot = try await client.withStableSnapshot { peer in
            try await read(payment, client: peer)
        }
        guard let result = snapshot.value else { return nil }
        guard result.height <= snapshot.tip.height else { throw BitcoinError.invalidResponse }
        return result
    }

    static func read(raw: Data, plan: BitcoinSendPlan, client: any BitcoinSendStatusReading) async throws -> BitcoinSendConfirmation? {
        try await read(Payment(raw: raw, plan: plan), client: client)
    }

    private static func read(_ payment: Payment, client: any BitcoinSendStatusReading) async throws -> BitcoinSendConfirmation? {
        let plan = payment.plan, raw = payment.raw
        let inputs = Set(plan.coins.map(\.id))
        let scripts = Array(Set(plan.coins.map { $0.address.scriptHash })).sorted()
        let histories = try await client.query(scriptHashes: scripts)
        var heights: [String: Int64] = [:]
        for item in histories.flatMap(\.history) {
            if let previous = heights[item.txid], previous != item.height { throw BitcoinError.invalidResponse }
            heights[item.txid] = item.height
        }
        if let height = heights[payment.txid], height > 0 {
            let fetched = try await client.transactions(txids: [payment.txid])
            guard fetched[payment.txid] == raw else { throw BitcoinError.invalidResponse }
            return try await receipt(raw, height: height, client: client)
        }
        if heights[payment.txid] != nil { return nil } // Still in this snapshot's mempool.
        // Only a mined, decoded double-spend can replace/cancel our transfer.
        // Page the complete relevant history so an old replacement is not lost
        // behind a fixed newest-N cutoff. Each request and page stays bounded.
        let parents = Set(plan.coins.map(\.txid))
        let candidates = heights.filter { $0.value > 0 && !parents.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        for start in stride(from: 0, to: candidates.count, by: 32) {
            try Task.checkCancellation()
            let page = candidates[start..<min(start + 32, candidates.count)]
            let bodies = try await client.transactions(txids: page.map(\.key))
            for item in page {
                guard let body = bodies[item.key] else { throw BitcoinError.invalidResponse }
                let tx = try BitcoinTransactions.details(body, network: plan.chain)
                guard tx.txid == item.key else { throw BitcoinError.invalidResponse }
                if !inputs.isDisjoint(with: tx.inputs.map(\.outpoint)) {
                    return try await receipt(body, height: item.value, client: client)
                }
            }
        }
        return nil
    }
    private static func receipt(_ raw: Data, height: Int64, client: any BitcoinSendStatusReading) async throws -> BitcoinSendConfirmation {
        guard let time = try await client.blockTimes(heights: [height])[height], time > 0 else { throw BitcoinError.invalidResponse }
        return .init(raw: raw, height: height, timestamp: time)
    }
}
