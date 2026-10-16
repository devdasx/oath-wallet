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
        let addresses = try await withThrowingTaskGroup(of: [BitcoinScannedAddress].self) { group in
            for branch in wallet.branches {
                group.addTask { try await scanBranch(branch, requiredThrough: requiredThrough[branch.id]) }
            }
            var all: [BitcoinScannedAddress] = []
            for try await records in group { all.append(contentsOf: records) }
            return all.sorted { $0.address.id.localizedStandardCompare($1.address.id) == .orderedAscending }
        }
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

    private func scanBranch(_ branch: BitcoinBranch, requiredThrough: UInt32?) async throws -> [BitcoinScannedAddress] {
        var cursor: UInt32 = 0
        var unused: UInt32 = 0
        var all: [BitcoinScannedAddress] = []
        repeat {
            try Task.checkCancellation()
            let end = branch.isHD ? cursor + Self.gapLimit : 1
            guard end <= maximumIndex else { throw BitcoinError.discoveryLimit }
            let addresses = try BitcoinKeys.addresses(branch: branch, range: cursor..<end)
            var states: [BitcoinAddressState] = []
            for attempt in 0..<3 {
                do { states = try await query.query(scriptHashes: addresses.map(\.scriptHash)); break }
                catch BitcoinError.inconsistentSnapshot where attempt < 2 { continue }
            }
            guard states.count == addresses.count else { throw BitcoinError.invalidResponse }
            for (address, state) in zip(addresses, states) {
                // get_history, not balance, defines the BIP44 address gap.
                unused = state.history.isEmpty ? unused + 1 : 0
                all.append(.init(address: address, state: state))
            }
            cursor = end
            if !branch.isHD { break }
        } while unused < Self.gapLimit || requiredThrough.map({ cursor <= $0 }) == true
        return all
    }
}
