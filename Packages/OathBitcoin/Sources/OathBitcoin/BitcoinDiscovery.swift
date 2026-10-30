import Foundation

public struct BitcoinScannedAddress: Codable, Equatable, Sendable {
    public let address: BitcoinDerivedAddress
    public let state: BitcoinAddressState
}

public struct BitcoinScan: Codable, Equatable, Sendable {
    public let addresses: [BitcoinScannedAddress]
    public let completedAt: Date
    public var confirmed: Int64 { addresses.reduce(0) { $0 + $1.state.confirmed } }
    public var unconfirmed: Int64 { addresses.reduce(0) { $0 + $1.state.unconfirmed } }
    /// Unconfirmed is a signed delta, not just incoming payments. Pending spends
    /// remove their inputs and pending change adds its outputs exactly once.
    public var total: Int64 { confirmed + unconfirmed }

    /// Recheck a complete snapshot at the persistence boundary. Decoded or
    /// truncated snapshots must never be able to replace a wallet ledger.
    public func validate(wallet: BitcoinWalletDescriptor, requiredThrough: [String: UInt32]) throws {
        guard completedAt.timeIntervalSince1970.isFinite, !wallet.branches.isEmpty, wallet.branches.allSatisfy({ $0.network == wallet.network }),
              Set(wallet.branches.map(\.id)).count == wallet.branches.count,
              Set(addresses.map { $0.address.branchID }) == Set(wallet.branches.map(\.id)),
              Set(addresses.map { $0.address.scriptHash }).count == addresses.count else { throw BitcoinError.invalidResponse }
        for branch in wallet.branches {
            let records = addresses.filter { $0.address.branchID == branch.id }.sorted { $0.address.index < $1.address.index }
            guard !records.isEmpty, records.count <= 100_000 else { throw BitcoinError.discoveryLimit }
            if branch.isHD {
                guard records.count % Int(BitcoinDiscovery.gapLimit) == 0,
                      records.suffix(Int(BitcoinDiscovery.gapLimit)).allSatisfy({ $0.state.history.isEmpty }),
                      requiredThrough[branch.id].map({ UInt32(records.count) > $0 }) ?? true else { throw BitcoinError.inconsistentSnapshot }
            } else { guard records.count == 1 else { throw BitcoinError.invalidResponse } }
            let expected = try BitcoinKeys.addresses(branch: branch, range: 0..<UInt32(records.count))
            guard records.map(\.address) == expected else { throw BitcoinError.invalidAddress }
        }
        var points = Set<String>(); var total: Int64 = 0
        var confirmed: Int64 = 0; var unconfirmed: Int64 = 0
        for record in addresses {
            let state = record.state
            guard (0...wallet.network.maximumMoney).contains(state.confirmed),
                  (-wallet.network.maximumMoney...wallet.network.maximumMoney).contains(state.unconfirmed),
                  Set(state.history.map(\.txid)).count == state.history.count,
                  state.history.allSatisfy({ ElectrumPool.hash($0.txid) && $0.height >= -1 }) else { throw BitcoinError.invalidResponse }
            let historyHeights = Dictionary(uniqueKeysWithValues: state.history.map { ($0.txid, $0.unspentHeight) })
            var value: Int64 = 0
            for output in state.unspent {
                guard points.insert(output.id).inserted, ElectrumPool.hash(output.txid), output.vout >= 0,
                      output.vout <= UInt32.max, output.height >= 0,
                      (0...wallet.network.maximumOutput).contains(output.value),
                      value <= wallet.network.maximumMoney - output.value,
                      state.history.contains(where: { $0.txid == output.txid }) else { throw BitcoinError.invalidResponse }
                value += output.value
                guard historyHeights[output.txid] == output.height else { throw BitcoinError.inconsistentSnapshot }
            }
            let combined = state.confirmed.addingReportingOverflow(state.unconfirmed)
            guard !combined.overflow, combined.partialValue == value,
                  total <= wallet.network.maximumMoney - value else { throw BitcoinError.inconsistentSnapshot }
            total += value
            let c = confirmed.addingReportingOverflow(state.confirmed)
            let u = unconfirmed.addingReportingOverflow(state.unconfirmed)
            guard !c.overflow, !u.overflow, (0...wallet.network.maximumMoney).contains(c.partialValue),
                  (-wallet.network.maximumMoney...wallet.network.maximumMoney).contains(u.partialValue) else { throw BitcoinError.invalidResponse }
            confirmed = c.partialValue; unconfirmed = u.partialValue
        }
        let combined = confirmed.addingReportingOverflow(unconfirmed)
        guard !combined.overflow, combined.partialValue == total else { throw BitcoinError.inconsistentSnapshot }
    }
}

public struct BitcoinDiscovery: Sendable {
    public static let gapLimit: UInt32 = 20
    private let query: any BitcoinAddressQuerying
    private let maximumIndex: UInt32
    public init(query: any BitcoinAddressQuerying, maximumIndex: UInt32 = 100_000) {
        self.query = query; self.maximumIndex = maximumIndex
    }

    /// A complete scan is the only result that may replace a wallet balance.
    /// Failure on ANY type/change branch cancels siblings and preserves the
    /// previous committed snapshot. No caller-selected Receive type is accepted.
    public func scan(_ wallet: BitcoinWalletDescriptor, requiredThrough: [String: UInt32] = [:]) async throws -> BitcoinScan {
        guard !wallet.branches.isEmpty, wallet.branches.allSatisfy({ $0.network == wallet.network }), Set(wallet.branches.map(\.id)).count == wallet.branches.count else { throw BitcoinError.invalidKey }
        let addresses = try await scanBranches(wallet.branches, requiredThrough: requiredThrough)
            .sorted { $0.address.id.localizedStandardCompare($1.address.id) == .orderedAscending }
        guard Set(addresses.map { $0.address.scriptHash }).count == addresses.count else { throw BitcoinError.invalidKey }
        var outpoints = Set<String>()
        var total: Int64 = 0
        for record in addresses {
            for output in record.state.unspent {
                guard outpoints.insert(output.id).inserted, output.value >= 0,
                      total <= wallet.network.maximumMoney - output.value else { throw BitcoinError.invalidResponse }
                total += output.value
            }
        }
        var confirmed: Int64 = 0; var unconfirmed: Int64 = 0
        for record in addresses {
            let c = confirmed.addingReportingOverflow(record.state.confirmed)
            let u = unconfirmed.addingReportingOverflow(record.state.unconfirmed)
            guard !c.overflow, !u.overflow, (0...wallet.network.maximumMoney).contains(c.partialValue),
                  (-wallet.network.maximumMoney...wallet.network.maximumMoney).contains(u.partialValue) else { throw BitcoinError.invalidResponse }
            confirmed = c.partialValue; unconfirmed = u.partialValue
        }
        let combined = confirmed.addingReportingOverflow(unconfirmed)
        guard !combined.overflow, confirmed <= wallet.network.maximumMoney, combined.partialValue == total else { throw BitcoinError.inconsistentSnapshot }
        return .init(addresses: addresses, completedAt: .now)
    }

    private struct BranchProgress: Sendable {
        var cursor: UInt32 = 0
        var unused: UInt32 = 0
        var window: UInt32 = gapLimit
        var complete = false
        var records: [BitcoinScannedAddress] = []
    }

    private func scanBranches(_ branches: [BitcoinBranch], requiredThrough: [String: UInt32]) async throws -> [BitcoinScannedAddress] {
        var progress = branches.map { _ in BranchProgress() }
        while progress.contains(where: { !$0.complete }) {
            try Task.checkCancellation()
            let indices = branches.indices.filter { !progress[$0].complete }
            let current = progress
            // Derive every script type and receive/change branch concurrently.
            // Combine their frontiers before querying so an empty 8-branch HD
            // wallet uses full server batches instead of eight tiny exchanges.
            let windows = try await BitcoinConcurrent.map(indices, limit: 8) { index in
                let branch = branches[index], state = current[index]
                let end: UInt32
                if branch.isHD {
                    let required = requiredThrough[branch.id].map { UInt64($0) + 1 } ?? 0
                    guard required <= UInt64(maximumIndex) else { throw BitcoinError.discoveryLimit }
                    let remaining = required > UInt64(state.cursor) ? required - UInt64(state.cursor) : 0
                    let rounded = ((remaining + UInt64(Self.gapLimit) - 1) / UInt64(Self.gapLimit)) * UInt64(Self.gapLimit)
                    let count = min(UInt64(5_000), max(UInt64(state.window), rounded))
                    // Keep complete gap-sized pages even at a custom scan cap.
                    let available = maximumIndex > state.cursor ? maximumIndex - state.cursor : 0
                    let bounded = min(count, UInt64((available / Self.gapLimit) * Self.gapLimit))
                    guard bounded > 0 else { throw BitcoinError.discoveryLimit }
                    end = state.cursor + UInt32(bounded)
                } else {
                    guard maximumIndex >= 1 else { throw BitcoinError.discoveryLimit }
                    end = 1
                }
                return try BitcoinKeys.addresses(branch: branch, range: state.cursor..<end)
            }
            let hashes = windows.flatMap { $0.map(\.scriptHash) }
            var states: [BitcoinAddressState] = []
            for attempt in 0..<3 {
                do { states = try await query.query(scriptHashes: hashes); break }
                catch BitcoinError.inconsistentSnapshot where attempt < 2 { continue }
            }
            try Task.checkCancellation()
            guard states.count == hashes.count else { throw BitcoinError.invalidResponse }
            var offset = 0
            for (index, addresses) in zip(indices, windows) {
                defer { offset += addresses.count }
                let branch = branches[index]
                for (address, state) in zip(addresses, states[offset..<(offset + addresses.count)]) {
                    // History (including spent addresses), never balance,
                    // defines the gap. Stop at exactly the same 20-address
                    // boundary as the old scanner, ignoring speculative tail.
                    progress[index].unused = state.history.isEmpty ? progress[index].unused + 1 : 0
                    progress[index].records.append(.init(address: address, state: state))
                    progress[index].cursor = address.index + 1
                    if !branch.isHD || (progress[index].cursor % Self.gapLimit == 0 &&
                        progress[index].unused >= Self.gapLimit &&
                        (requiredThrough[branch.id].map { progress[index].cursor > $0 } ?? true)) {
                        progress[index].complete = true
                        break
                    }
                }
                // Grow only branches which actually need more discovery. New
                // empty wallets still query exactly the original gap window.
                progress[index].window = min(5_000, max(100, progress[index].window * 2))
            }
        }
        return progress.flatMap(\.records)
    }
}
