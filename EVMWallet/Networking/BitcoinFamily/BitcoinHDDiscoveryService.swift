import Foundation

struct BitcoinHDTransactionReference: Hashable, Sendable {
    let transactionHash: String
    let height: Int64
}

struct BitcoinHDDiscoveryResult: Sendable {
    let states: [BitcoinHDAddressState]
    let balanceAtomic: BitcoinFamilyAtomicInteger
    let transactions: [BitcoinHDTransactionReference]
    let receiveAddress: BitcoinHDDerivedAddress
}

enum BitcoinHDDiscoveryError: Error, Equatable {
    case unsupportedWallet
    case incompleteAccountDescriptors
    case invalidElectrumResponse
    case missingReceiveAddress
}

actor BitcoinHDDiscoveryService {
    private struct BranchResult: Sendable {
        let states: [BitcoinHDAddressState]
        let transactions: Set<BitcoinHDTransactionReference>
    }

    private struct BalanceBranchCursor: Sendable {
        let descriptor: BitcoinHDAccountDescriptor
        let branch: BitcoinHDAddressBranch
        var scanStart: Int
        var scanCount: Int
        var states: [BitcoinHDAddressState]
        var isComplete: Bool
    }

    private struct BalanceBranchWindow: Sendable {
        let cursorIndex: Int
        let scanEnd: Int
        let states: [BitcoinHDAddressState]
    }

    static let shared = BitcoinHDDiscoveryService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let electrum: BitcoinFamilyElectrumClient

    init(
        database: WalletDatabase,
        electrum: BitcoinFamilyElectrumClient = .shared
    ) {
        databaseProvider = { database }
        self.electrum = electrum
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        electrum = .shared
    }

    private var database: WalletDatabase {
        get throws { try databaseProvider() }
    }

    func discover(walletID: String) async throws
        -> BitcoinHDDiscoveryResult {
        guard try await database.ensureBitcoinHDWallet(
            walletID: walletID
        ) else {
            throw BitcoinHDDiscoveryError.unsupportedWallet
        }
        let descriptors = try await database.bitcoinHDAccountDescriptors(
            walletID: walletID
        )
        guard !descriptors.isEmpty,
              Set(descriptors.map(\.addressType)).count
                == descriptors.count else {
            throw BitcoinHDDiscoveryError.incompleteAccountDescriptors
        }

        let branchResults = try await withThrowingTaskGroup(
            of: BranchResult.self
        ) { group in
            for descriptor in descriptors {
                for branch in [
                    BitcoinHDAddressBranch.external,
                    BitcoinHDAddressBranch.change
                ] {
                    group.addTask {
                        try await self.discover(
                            walletID: walletID,
                            descriptor: descriptor,
                            branch: branch
                        )
                    }
                }
            }
            var values: [BranchResult] = []
            values.reserveCapacity(descriptors.count * 2)
            while let value = try await group.next() {
                values.append(value)
            }
            return values
        }

        return try await result(
            walletID: walletID,
            branchResults: branchResults
        )
    }

    /// Refreshes spendable balances and gap-limit state without also loading
    /// transaction history. History has its own synchronization path; issuing
    /// both RPCs during a balance refresh doubled the largest HD wallet scan.
    func refreshBalances(walletID: String) async throws
        -> BitcoinHDDiscoveryResult {
        guard try await database.ensureBitcoinHDWallet(
            walletID: walletID
        ) else {
            throw BitcoinHDDiscoveryError.unsupportedWallet
        }
        let descriptors = try await database.bitcoinHDAccountDescriptors(
            walletID: walletID
        )
        guard !descriptors.isEmpty,
              Set(descriptors.map(\.addressType)).count
                == descriptors.count else {
            throw BitcoinHDDiscoveryError.incompleteAccountDescriptors
        }
        let branchResults = try await refreshBalanceBranches(
            walletID: walletID,
            descriptors: descriptors
        )
        return try await result(
            walletID: walletID,
            branchResults: branchResults
        )
    }

    private func result(
        walletID: String,
        branchResults: [BranchResult]
    ) async throws -> BitcoinHDDiscoveryResult {

        let states = branchResults
            .flatMap(\.states)
            .sorted {
                if $0.derived.addressType != $1.derived.addressType {
                    return $0.derived.addressType.rawValue
                        < $1.derived.addressType.rawValue
                }
                if $0.derived.branch != $1.derived.branch {
                    return $0.derived.branch.rawValue
                        < $1.derived.branch.rawValue
                }
                return $0.derived.index < $1.derived.index
            }
        var balance = BitcoinFamilyAtomicInteger.zero
        for state in states {
            let addressBalance = state.balanceAtomic
            guard !addressBalance.isNegative else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }
            balance = balance.adding(addressBalance)
        }

        let transactions = Set(
            branchResults.flatMap(\.transactions)
        ).sorted {
            let leftPending = $0.height <= 0
            let rightPending = $1.height <= 0
            if leftPending != rightPending { return leftPending }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.transactionHash < $1.transactionHash
        }
        try await database.publishFreshBitcoinReceiveAddress(
            walletID: walletID
        )
        let receiveType = try await database.bitcoinReceiveAddressType(
            walletID: walletID
        )
        guard let receiveAddress = try await database
            .freshBitcoinReceiveAddress(
                walletID: walletID,
                addressType: receiveType
            ) else {
            throw BitcoinHDDiscoveryError.missingReceiveAddress
        }
        return BitcoinHDDiscoveryResult(
            states: states,
            balanceAtomic: balance,
            transactions: transactions,
            receiveAddress: receiveAddress
        )
    }

    private func refreshBalanceBranches(
        walletID: String,
        descriptors: [BitcoinHDAccountDescriptor]
    ) async throws -> [BranchResult] {
        var cursors: [BalanceBranchCursor] = []
        cursors.reserveCapacity(descriptors.count * 2)
        for descriptor in descriptors {
            for branch in [
                BitcoinHDAddressBranch.external,
                BitcoinHDAddressBranch.change
            ] {
                let known = try await database.bitcoinHDAddresses(
                    walletID: walletID,
                    addressType: descriptor.addressType,
                    branch: branch
                )
                let lastKnownUsed = known.lazy
                    .filter { $0.isUsed || $0.isReserved }
                    .map(\.derived.index)
                    .max() ?? -1
                let requiredCount = lastKnownUsed + 1
                    + BitcoinHDDerivationService.gapLimit
                guard requiredCount > 0,
                      requiredCount <= Int(UInt32.max) else {
                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                }
                cursors.append(
                    BalanceBranchCursor(
                        descriptor: descriptor,
                        branch: branch,
                        scanStart: 0,
                        scanCount: max(
                            BitcoinHDDerivationService.gapLimit,
                            requiredCount
                        ),
                        states: [],
                        isComplete: false
                    )
                )
            }
        }

        while cursors.contains(where: { !$0.isComplete }) {
            try Task.checkCancellation()
            var windows: [BalanceBranchWindow] = []
            for cursorIndex in cursors.indices
                where !cursors[cursorIndex].isComplete {
                let cursor = cursors[cursorIndex]
                guard cursor.scanCount > 0,
                      cursor.scanStart <= Int(UInt32.max)
                        - cursor.scanCount + 1 else {
                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                }
                let scanEnd = cursor.scanStart + cursor.scanCount - 1
                let available = try await database.ensureBitcoinHDAddressRange(
                    walletID: walletID,
                    descriptor: cursor.descriptor,
                    branch: cursor.branch,
                    through: scanEnd
                )
                let states = available.filter {
                    $0.derived.index >= cursor.scanStart
                        && $0.derived.index <= scanEnd
                }
                guard states.count == cursor.scanCount else {
                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                }
                windows.append(
                    BalanceBranchWindow(
                        cursorIndex: cursorIndex,
                        scanEnd: scanEnd,
                        states: states
                    )
                )
            }

            let requestedStates = windows.flatMap(\.states)
            guard !requestedStates.isEmpty else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }
            let balances = try await electrum.callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: requestedStates.map(\.derived.scriptHash)
            )
            guard balances.count == requestedStates.count else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }

            var saveStates: [BitcoinHDAddressState] = []
            saveStates.reserveCapacity(requestedStates.count)
            var responseOffset = 0
            for window in windows {
                let responseEnd = responseOffset + window.states.count
                let liveStates = try Self.parseBalances(
                    states: window.states,
                    balances: Array(balances[responseOffset..<responseEnd])
                )
                responseOffset = responseEnd
                saveStates.append(contentsOf: liveStates)
                cursors[window.cursorIndex].states.append(
                    contentsOf: liveStates
                )

                if Self.hasGapLimitAfterLastUsed(
                    cursors[window.cursorIndex].states
                ) {
                    cursors[window.cursorIndex].isComplete = true
                    continue
                }
                let lastUnavailable = cursors[window.cursorIndex].states.lazy
                    .filter { $0.isUsed || $0.isReserved }
                    .map(\.derived.index)
                    .max() ?? -1
                let requiredEnd = lastUnavailable
                    + BitcoinHDDerivationService.gapLimit
                let nextStart = window.scanEnd + 1
                guard requiredEnd >= nextStart,
                      requiredEnd <= Int(UInt32.max) else {
                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                }
                cursors[window.cursorIndex].scanStart = nextStart
                cursors[window.cursorIndex].scanCount = requiredEnd
                    - nextStart + 1
            }
            try await validateZeroBalanceDowngrades(
                previous: requestedStates,
                refreshed: saveStates
            )
            try await database.saveBitcoinHDAddressStates(
                saveStates,
                walletID: walletID
            )
        }
        return cursors.map {
            BranchResult(states: $0.states, transactions: [])
        }
    }

    private func discover(
        walletID: String,
        descriptor: BitcoinHDAccountDescriptor,
        branch: BitcoinHDAddressBranch
    ) async throws -> BranchResult {
        var finalStates: [BitcoinHDAddressState] = []
        var transactions = Set<BitcoinHDTransactionReference>()
        let known = try await database.bitcoinHDAddresses(
            walletID: walletID,
            addressType: descriptor.addressType,
            branch: branch
        )
        let lastKnownUsed = known.lazy
            .filter { $0.isUsed || $0.isReserved }
            .map(\.derived.index)
            .max() ?? -1
        let requiredInitialCount = lastKnownUsed + 1
            + BitcoinHDDerivationService.gapLimit
        guard requiredInitialCount > 0,
              requiredInitialCount <= Int(UInt32.max) else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        var scanStart = 0
        var scanCount = max(
            BitcoinHDDerivationService.gapLimit,
            requiredInitialCount
        )

        while true {
            try Task.checkCancellation()
            let scanEnd = scanStart + scanCount - 1
            let available = try await database.ensureBitcoinHDAddressRange(
                walletID: walletID,
                descriptor: descriptor,
                branch: branch,
                through: scanEnd
            )
            let window = available.filter {
                $0.derived.index >= scanStart
                    && $0.derived.index <= scanEnd
            }
            guard window.count == scanCount else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }

            async let historyValues = electrum.callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_history",
                parameters: window.map(\.derived.scriptHash),
                maximumResponseBytes:
                    BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
            )
            async let balanceValues = electrum.callStringParameterBatch(
                chain: .bitcoin,
                method: "blockchain.scripthash.get_balance",
                parameters: window.map(\.derived.scriptHash)
            )
            let liveStates = try Self.parse(
                states: window,
                histories: await historyValues,
                balances: await balanceValues,
                transactions: &transactions
            )
            try Task.checkCancellation()
            try await database.saveBitcoinHDAddressDiscoveryStates(
                liveStates,
                walletID: walletID
            )
            finalStates.append(contentsOf: liveStates)

            guard !Self.hasGapLimitAfterLastUsed(finalStates) else {
                break
            }
            scanStart = scanEnd + 1
            let lastUnavailable = finalStates.lazy
                .filter { $0.isUsed || $0.isReserved }
                .map(\.derived.index)
                .max() ?? -1
            let requiredEnd = lastUnavailable
                + BitcoinHDDerivationService.gapLimit
            guard requiredEnd >= scanStart,
                  requiredEnd <= Int(UInt32.max) else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }
            scanCount = requiredEnd - scanStart + 1
        }
        return BranchResult(
            states: finalStates,
            transactions: transactions
        )
    }

    static func parse(
        states: [BitcoinHDAddressState],
        histories: [BitcoinFamilyElectrumBatchValue],
        balances: [BitcoinFamilyElectrumBatchValue],
        transactions: inout Set<BitcoinHDTransactionReference>
    ) throws -> [BitcoinHDAddressState] {
        guard histories.count == states.count,
              balances.count == states.count else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        let historiesByHash = Dictionary(
            uniqueKeysWithValues: histories.map {
                ($0.parameter, $0.value)
            }
        )
        let balancesByHash = Dictionary(
            uniqueKeysWithValues: balances.map {
                ($0.parameter, $0.value)
            }
        )
        return try states.map { state in
            let scriptHash = state.derived.scriptHash
            guard let rawHistory = historiesByHash[scriptHash]?.array,
                  let balance = balancesByHash[scriptHash]?.object,
                  let confirmed = balance["confirmed"]?.atomicInteger,
                  let unconfirmed = balance["unconfirmed"]?.atomicInteger,
                  !confirmed.isNegative,
                  !confirmed.adding(unconfirmed).isNegative else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }
            // A removed unconfirmed payment may leave both balance and history
            // empty. Preserve address discovery, but accept the fresh zero.
            for rawItem in rawHistory {
                guard let item = rawItem.object,
                      let hash = item["tx_hash"]?.string,
                      Self.isValidTransactionHash(hash),
                      let height = item["height"]?.exactInt64 else {
                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                }
                transactions.insert(
                    BitcoinHDTransactionReference(
                        transactionHash: hash,
                        height: height
                    )
                )
            }
            return BitcoinHDAddressState(
                derived: state.derived,
                isUsed: state.isUsed
                    || !rawHistory.isEmpty
                    || !confirmed.isZero
                    || !unconfirmed.isZero,
                isReserved: state.isReserved && rawHistory.isEmpty,
                confirmedBalanceAtomic: confirmed,
                unconfirmedBalanceAtomic: unconfirmed
            )
        }
    }

    static func parseBalances(
        states: [BitcoinHDAddressState],
        balances: [BitcoinFamilyElectrumBatchValue]
    ) throws -> [BitcoinHDAddressState] {
        guard balances.count == states.count else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        let balancesByHash = Dictionary(
            uniqueKeysWithValues: balances.map {
                ($0.parameter, $0.value)
            }
        )
        return try states.map { state in
            guard let balance = balancesByHash[state.derived.scriptHash]?
                    .object,
                  let confirmed = balance["confirmed"]?.atomicInteger,
                  let unconfirmed = balance["unconfirmed"]?.atomicInteger,
                  !confirmed.isNegative,
                  !confirmed.adding(unconfirmed).isNegative else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }
            let hasBalance = !confirmed.isZero || !unconfirmed.isZero
            return BitcoinHDAddressState(
                derived: state.derived,
                isUsed: state.isUsed || hasBalance,
                isReserved: state.isReserved && !hasBalance,
                confirmedBalanceAtomic: confirmed,
                unconfirmedBalanceAtomic: unconfirmed
            )
        }
    }

    private func validateZeroBalanceDowngrades(
        previous: [BitcoinHDAddressState],
        refreshed: [BitcoinHDAddressState]
    ) async throws {
        let priorByHash = Dictionary(
            uniqueKeysWithValues: previous.map {
                ($0.derived.scriptHash, $0)
            }
        )
        let downgradedHashes: [String] = refreshed.compactMap { state in
            guard let prior = priorByHash[state.derived.scriptHash],
                  !prior.balanceAtomic.isZero,
                  state.balanceAtomic.isZero else { return nil }
            return state.derived.scriptHash
        }
        guard !downgradedHashes.isEmpty else { return }

        let histories = try await electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.get_history",
            parameters: downgradedHashes,
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        guard histories.count == downgradedHashes.count else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        let historyByHash: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: histories.map {
                ($0.parameter, $0.value)
            }
        )
        for hash in downgradedHashes {
            guard let rows = historyByHash[hash]?.array else {
                throw BitcoinHDDiscoveryError.invalidElectrumResponse
            }
            for row in rows {
                guard let item = row.object,
                      let transactionHash = item["tx_hash"]?.string,
                      Self.isValidTransactionHash(transactionHash),
                      item["height"]?.exactInt64 != nil else {
                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                }
            }
        }
    }

    private nonisolated static func isValidTransactionHash(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }

    static func hasGapLimitAfterLastUsed(
        _ states: [BitcoinHDAddressState]
    ) -> Bool {
        guard states.count >= BitcoinHDDerivationService.gapLimit else {
            return false
        }
        let sorted = states.sorted {
            $0.derived.index < $1.derived.index
        }
        let lastUsedIndex = sorted.last(where: {
            $0.isUsed || $0.isReserved
        })?.derived.index ?? -1
        return sorted.lazy
            .filter { $0.derived.index > lastUsedIndex }
            .prefix(BitcoinHDDerivationService.gapLimit)
            .count == BitcoinHDDerivationService.gapLimit
    }
}
