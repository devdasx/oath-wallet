import Foundation

struct MuunRecoveryDiscoveryResult: Sendable {
    let states: [MuunRecoveryAddressState]
    let balanceAtomic: BitcoinFamilyAtomicInteger
    let transactions: [BitcoinHDTransactionReference]
    let receiveAddress: MuunRecoveryDerivedAddress
}

enum MuunRecoveryDiscoveryError: Error, Equatable {
    case unsupportedWallet
    case invalidElectrumResponse
    case missingReceiveAddress
}

actor MuunRecoveryDiscoveryService {
    private struct QueryResult: Sendable {
        let states: [MuunRecoveryAddressState]
        let transactions: Set<BitcoinHDTransactionReference>
    }

    static let shared = MuunRecoveryDiscoveryService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let changePathCount = 2_501
    private static let externalPathCount = 2_501
    private static let contactCount = 101
    private static let contactAddressCount = 201
    private static let totalPathCount = changePathCount
        + externalPathCount
        + contactCount * contactAddressCount
    private static let pathBatchCount = 64
    private static let futureGapLimit = 20

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

    func discover(
        walletID: String
    ) async throws -> MuunRecoveryDiscoveryResult {
        guard var wallet = try await database.muunRecoveryWallet(
            walletID: walletID
        ) else {
            throw MuunRecoveryDiscoveryError.unsupportedWallet
        }
        let material = try await database.muunRecoveryKeyMaterial(
            walletID: walletID
        )
        if !wallet.fullScanCompleted {
            try await runOfficialRecoveryScan(
                walletID: walletID,
                material: material,
                startingAt: wallet.recoveryScanCursor
            )
            guard let refreshed = try await database.muunRecoveryWallet(
                walletID: walletID
            ) else {
                throw MuunRecoveryDiscoveryError.unsupportedWallet
            }
            wallet = refreshed
        }
        guard wallet.fullScanCompleted else {
            throw MuunRecoveryDiscoveryError.invalidElectrumResponse
        }

        let refreshed = try await refreshPersistedAndFutureAddresses(
            walletID: walletID,
            material: material
        )
        try await database.publishFreshMuunRecoveryReceiveAddress(
            walletID: walletID
        )
        guard let receiveAddress = try await database
            .freshMuunRecoveryReceiveAddress(walletID: walletID) else {
            throw MuunRecoveryDiscoveryError.missingReceiveAddress
        }
        let states = try await database.muunRecoveryAddresses(
            walletID: walletID
        )
        var balance = BitcoinFamilyAtomicInteger.zero
        for state in states {
            guard !state.balanceAtomic.isNegative else {
                throw MuunRecoveryDiscoveryError.invalidElectrumResponse
            }
            balance = balance.adding(state.balanceAtomic)
        }
        return MuunRecoveryDiscoveryResult(
            states: states,
            balanceAtomic: balance,
            transactions: Self.sorted(refreshed.transactions),
            receiveAddress: receiveAddress
        )
    }

    func refreshBalances(
        walletID: String
    ) async throws -> MuunRecoveryDiscoveryResult {
        try await discover(walletID: walletID)
    }

    private func runOfficialRecoveryScan(
        walletID: String,
        material: MuunRecoveryKeyMaterial,
        startingAt cursor: Int
    ) async throws {
        guard cursor >= 0, cursor <= Self.totalPathCount else {
            throw MuunRecoveryDiscoveryError.invalidElectrumResponse
        }
        let existing = try await database.muunRecoveryAddresses(
            walletID: walletID
        )
        let existingByHash = Dictionary(
            uniqueKeysWithValues: existing.map {
                ($0.derived.scriptHash, $0)
            }
        )
        var start = cursor
        while start < Self.totalPathCount {
            try Task.checkCancellation()
            let end = min(
                start + Self.pathBatchCount,
                Self.totalPathCount
            )
            var addresses: [MuunRecoveryDerivedAddress] = []
            addresses.reserveCapacity((end - start) * 4)
            for pathCursor in start..<end {
                let location = try Self.location(for: pathCursor)
                addresses.append(contentsOf: try MuunRecoveryAddressFactory
                    .deriveAll(
                        material: material,
                        branch: location.branch,
                        contactIndex: location.contactIndex,
                        addressIndex: location.addressIndex
                    ))
            }
            let queried = try await query(
                addresses: addresses,
                existingByHash: existingByHash
            )
            let statesToPersist = queried.states.filter {
                $0.isUsed || $0.isReserved
                    || existingByHash[$0.derived.scriptHash] != nil
            }
            try await database.saveMuunRecoveryScanBatch(
                walletID: walletID,
                states: statesToPersist,
                nextCursor: end,
                fullScanCompleted: end == Self.totalPathCount
            )
            start = end
        }
    }

    private func refreshPersistedAndFutureAddresses(
        walletID: String,
        material: MuunRecoveryKeyMaterial
    ) async throws -> QueryResult {
        let existing = try await database.muunRecoveryAddresses(
            walletID: walletID
        )
        var persistedByHash = Dictionary(
            uniqueKeysWithValues: existing.map {
                ($0.derived.scriptHash, $0)
            }
        )
        var allTransactions = Set<BitcoinHDTransactionReference>()
        if !existing.isEmpty {
            let known = try await query(
                addresses: existing.map(\.derived),
                existingByHash: persistedByHash
            )
            try await database.saveMuunRecoveryAddressStates(
                known.states,
                walletID: walletID
            )
            allTransactions.formUnion(known.transactions)
            for state in known.states {
                persistedByHash[state.derived.scriptHash] = state
            }
        }

        for branch in [
            MuunRecoveryAddressBranch.external,
            MuunRecoveryAddressBranch.change,
        ] {
            var lastUnavailable = existing.lazy
                .filter {
                    $0.derived.branch == branch
                        && $0.derived.contactIndex == nil
                        && ($0.isUsed || $0.isReserved)
                }
                .map(\.derived.addressIndex)
                .max() ?? -1
            var scanStart = lastUnavailable + 1
            while true {
                try Task.checkCancellation()
                let scanEnd = scanStart + Self.futureGapLimit - 1
                let addresses = try (scanStart...scanEnd).map { index in
                    try MuunRecoveryAddressFactory.derive(
                        material: material,
                        version: .v5,
                        branch: branch,
                        addressIndex: index
                    )
                }
                let queried = try await query(
                    addresses: addresses,
                    existingByHash: persistedByHash
                )
                let retained = queried.states.filter {
                    $0.isUsed || $0.isReserved
                        || persistedByHash[$0.derived.scriptHash] != nil
                        || (
                            branch == .external
                                && $0.derived.addressIndex == scanStart
                        )
                }
                try await database.saveMuunRecoveryAddressStates(
                    retained,
                    walletID: walletID
                )
                allTransactions.formUnion(queried.transactions)
                for state in retained {
                    persistedByHash[state.derived.scriptHash] = state
                }
                let newestUsed = queried.states.lazy
                    .filter { $0.isUsed || $0.isReserved }
                    .map(\.derived.addressIndex)
                    .max() ?? lastUnavailable
                if newestUsed <= lastUnavailable { break }
                lastUnavailable = newestUsed
                scanStart = lastUnavailable + 1
            }
        }
        return QueryResult(
            states: Array(persistedByHash.values),
            transactions: allTransactions
        )
    }

    private func query(
        addresses: [MuunRecoveryDerivedAddress],
        existingByHash: [String: MuunRecoveryAddressState]
    ) async throws -> QueryResult {
        guard !addresses.isEmpty else {
            return QueryResult(states: [], transactions: [])
        }
        let hashes = addresses.map(\.scriptHash)
        guard Set(hashes).count == hashes.count else {
            throw MuunRecoveryDiscoveryError.invalidElectrumResponse
        }
        let histories = try await electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.get_history",
            parameters: hashes,
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        guard histories.count == addresses.count else {
            throw MuunRecoveryDiscoveryError.invalidElectrumResponse
        }
        let historyByHash = Dictionary(
            uniqueKeysWithValues: histories.map {
                ($0.parameter, $0.value)
            }
        )
        var transactions = Set<BitcoinHDTransactionReference>()
        var usedHashes: [String] = []
        usedHashes.reserveCapacity(addresses.count)
        for address in addresses {
            guard let rows = historyByHash[address.scriptHash]?.array else {
                throw MuunRecoveryDiscoveryError.invalidElectrumResponse
            }
            if !rows.isEmpty
                || existingByHash[address.scriptHash]?.isUsed == true
                || existingByHash[address.scriptHash]?.isReserved == true {
                usedHashes.append(address.scriptHash)
            }
            for row in rows {
                guard let item = row.object,
                      let hash = item["tx_hash"]?.string,
                      Self.validTransactionHash(hash),
                      let height = item["height"]?.exactInt64 else {
                    throw MuunRecoveryDiscoveryError
                        .invalidElectrumResponse
                }
                transactions.insert(
                    BitcoinHDTransactionReference(
                        transactionHash: hash.lowercased(),
                        height: height
                    )
                )
            }
        }
        let balances = try await electrum.callStringParameterBatch(
            chain: .bitcoin,
            method: "blockchain.scripthash.get_balance",
            parameters: usedHashes
        )
        guard balances.count == usedHashes.count else {
            throw MuunRecoveryDiscoveryError.invalidElectrumResponse
        }
        let balanceByHash = Dictionary(
            uniqueKeysWithValues: balances.map {
                ($0.parameter, $0.value)
            }
        )
        let zero = BitcoinFamilyAtomicInteger.zero
        let states = try addresses.map { address in
            guard let rows = historyByHash[address.scriptHash]?.array else {
                throw MuunRecoveryDiscoveryError.invalidElectrumResponse
            }
            let existing = existingByHash[address.scriptHash]
            let confirmed: BitcoinFamilyAtomicInteger
            let unconfirmed: BitcoinFamilyAtomicInteger
            if usedHashes.contains(address.scriptHash) {
                guard let balance = balanceByHash[address.scriptHash]?.object,
                      let confirmedValue = balance["confirmed"]?
                        .atomicInteger,
                      let unconfirmedValue = balance["unconfirmed"]?
                        .atomicInteger,
                      !confirmedValue.isNegative,
                      !confirmedValue.adding(unconfirmedValue).isNegative
                else {
                    throw MuunRecoveryDiscoveryError
                        .invalidElectrumResponse
                }
                confirmed = confirmedValue
                unconfirmed = unconfirmedValue
            } else {
                confirmed = zero
                unconfirmed = zero
            }
            let isUsed = existing?.isUsed == true
                || !rows.isEmpty
                || !confirmed.isZero
                || !unconfirmed.isZero
            return MuunRecoveryAddressState(
                derived: address,
                isUsed: isUsed,
                isReserved: existing?.isReserved == true && !isUsed,
                confirmedBalanceAtomic: confirmed,
                unconfirmedBalanceAtomic: unconfirmed
            )
        }
        return QueryResult(states: states, transactions: transactions)
    }

    private nonisolated static func location(
        for cursor: Int
    ) throws -> (
        branch: MuunRecoveryAddressBranch,
        contactIndex: Int?,
        addressIndex: Int
    ) {
        guard cursor >= 0, cursor < totalPathCount else {
            throw MuunRecoveryDiscoveryError.invalidElectrumResponse
        }
        if cursor < changePathCount {
            return (.change, nil, cursor)
        }
        let afterChange = cursor - changePathCount
        if afterChange < externalPathCount {
            return (.external, nil, afterChange)
        }
        let contactOffset = afterChange - externalPathCount
        return (
            .contacts,
            contactOffset / contactAddressCount,
            contactOffset % contactAddressCount
        )
    }

    private nonisolated static func validTransactionHash(
        _ value: String
    ) -> Bool {
        value.utf8.count == 64 && value.unicodeScalars.allSatisfy {
            switch $0.value {
            case 48...57, 65...70, 97...102: true
            default: false
            }
        }
    }

    private nonisolated static func sorted(
        _ values: Set<BitcoinHDTransactionReference>
    ) -> [BitcoinHDTransactionReference] {
        values.sorted {
            let leftPending = $0.height <= 0
            let rightPending = $1.height <= 0
            if leftPending != rightPending { return leftPending }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.transactionHash < $1.transactionHash
        }
    }
}
