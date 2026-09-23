import Foundation

struct BitcoinFamilyHDDiscoveryResult: Sendable {
    let states: [BitcoinHDAddressState]
    let transactions: [BitcoinHDTransactionReference]
    let balance: BitcoinFamilyAtomicInteger
    let receiveAddress: BitcoinHDDerivedAddress
}

/// A balance refresh, history refresh and send review share one scan even
/// when their service instances differ. Separate databases never share work.
actor BitcoinFamilyHDScanCoordinator {
    static let shared = BitcoinFamilyHDScanCoordinator()
    struct Key: Hashable, Sendable {
        let database: ObjectIdentifier
        let walletID: String
        let chain: BitcoinFamilyChain
    }
    private var scans: [Key: Task<BitcoinFamilyHDDiscoveryResult, Error>] = [:]

    func run(key: Key, operation: @escaping @Sendable () async throws -> BitcoinFamilyHDDiscoveryResult)
        async throws -> BitcoinFamilyHDDiscoveryResult {
        if let task = scans[key] { return try await task.value }
        let task = Task { try await operation() }
        scans[key] = task
        defer { scans[key] = nil }
        return try await task.value
    }
}

actor BitcoinFamilyHDDiscoveryService {
    static let shared = BitcoinFamilyHDDiscoveryService(databaseProvider: { try WalletDatabaseRuntime.require() })
    private let databaseProvider: @Sendable () throws -> WalletDatabase
    private let electrum: BitcoinFamilyElectrumClient

    init(database: WalletDatabase, electrum: BitcoinFamilyElectrumClient = .shared) {
        databaseProvider = { database }
        self.electrum = electrum
    }
    private init(databaseProvider: @escaping @Sendable () throws -> WalletDatabase) {
        self.databaseProvider = databaseProvider
        electrum = .shared
    }

    func supports(walletID: String, chain: BitcoinFamilyChain) async throws -> Bool {
        try await databaseProvider().ensureBitcoinFamilyHDWallet(walletID: walletID, chain: chain)
    }

    func discover(walletID: String, chain: BitcoinFamilyChain) async throws -> BitcoinFamilyHDDiscoveryResult {
        let database = try databaseProvider()
        let key = BitcoinFamilyHDScanCoordinator.Key(database: ObjectIdentifier(database.pool), walletID: walletID, chain: chain)
        return try await BitcoinFamilyHDScanCoordinator.shared.run(key: key) {
            try await self.scan(walletID: walletID, chain: chain, database: database)
        }
    }

    private struct AddressResult: Sendable {
        let state: BitcoinHDAddressState
        let history: [BitcoinHDTransactionReference]
    }

    private func scan(walletID: String, chain: BitcoinFamilyChain, database: WalletDatabase) async throws -> BitcoinFamilyHDDiscoveryResult {
        guard try await database.ensureBitcoinFamilyHDWallet(walletID: walletID, chain: chain) else {
            throw BitcoinHDDiscoveryError.unsupportedWallet
        }
        let descriptors = try await database.bitcoinFamilyHDDescriptors(walletID: walletID, chain: chain)
        let previous = try await database.bitcoinFamilyHDAddresses(walletID: walletID, chain: chain)
        let results = try await withThrowingTaskGroup(of: [AddressResult].self) { group in
            for descriptor in descriptors {
                for branch in [BitcoinHDAddressBranch.external, .change] {
                    let highWater = previous.filter { $0.derived.addressType == descriptor.type
                        && $0.derived.branch == branch && ($0.isUsed || $0.isReserved) }.map(\.derived.index).max() ?? -1
                    group.addTask {
                        try await HDGapDiscovery.scan(gapLimit: BitcoinFamilyHDDerivation.gapLimit,
                            highestKnownUsedIndex: highWater) { range in
                            let states = try await database.ensureBitcoinFamilyHDRange(walletID: walletID,
                                descriptor: descriptor, branch: branch, range: range)
                            let hashes = states.map(\.derived.scriptHash)
                            async let balances = self.electrum.callStringParameterBatch(chain: chain,
                                method: "blockchain.scripthash.get_balance", parameters: hashes)
                            async let histories = self.electrum.callStringParameterBatch(chain: chain,
                                method: "blockchain.scripthash.get_history", parameters: hashes,
                                maximumResponseBytes: BitcoinFamilyElectrumClient.maximumHistoryResponseBytes)
                            let (balanceValues, historyValues) = try await (balances, histories)
                            guard balanceValues.count == states.count, historyValues.count == states.count,
                                  Set(balanceValues.map(\.parameter)) == Set(hashes),
                                  Set(historyValues.map(\.parameter)) == Set(hashes) else {
                                throw BitcoinHDDiscoveryError.invalidElectrumResponse
                            }
                            let balancesByHash = Dictionary(uniqueKeysWithValues: balanceValues.map { ($0.parameter, $0.value) })
                            let historiesByHash = Dictionary(uniqueKeysWithValues: historyValues.map { ($0.parameter, $0.value) })
                            return try states.map { state in
                                guard let balance = balancesByHash[state.derived.scriptHash]?.object,
                                      let confirmed = balance["confirmed"]?.atomicInteger,
                                      let unconfirmed = balance["unconfirmed"]?.atomicInteger,
                                      !confirmed.isNegative, !confirmed.adding(unconfirmed).isNegative,
                                      let history = historiesByHash[state.derived.scriptHash]?.array else {
                                    throw BitcoinHDDiscoveryError.invalidElectrumResponse
                                }
                                let references = try history.map { value -> BitcoinHDTransactionReference in
                                    guard let object = value.object, let hash = object["tx_hash"]?.string,
                                          hash.count == 64, Data(bitcoinHex: hash)?.count == 32,
                                          let height = object["height"]?.exactInt64, height >= -1 else {
                                        throw BitcoinHDDiscoveryError.invalidElectrumResponse
                                    }
                                    return BitcoinHDTransactionReference(transactionHash: hash.lowercased(), height: height)
                                }
                                let used = state.isUsed || !references.isEmpty || !confirmed.isZero || !unconfirmed.isZero
                                let refreshed = BitcoinHDAddressState(derived: state.derived, isUsed: used,
                                    isReserved: state.isReserved, confirmedBalanceAtomic: confirmed,
                                    unconfirmedBalanceAtomic: unconfirmed)
                                return HDGapDiscovery.Observation(index: state.derived.index,
                                    isUsed: used || state.isReserved,
                                    value: AddressResult(state: refreshed, history: references))
                            }
                        }
                    }
                }
            }
            var results: [AddressResult] = []
            for try await branch in group { results += branch }
            return results
        }
        // Do not write a partial branch/chain result if one provider request failed.
        let states = results.map(\.state)
        guard Set(states.map(\.derived.scriptHash)).count == states.count else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        // Empty successful reads are authoritative too: a replaced first
        // payment leaves no balance or history. Failed/partial reads throw above.
        try Task.checkCancellation()
        try await database.saveBitcoinFamilyHDStates(states, walletID: walletID, chain: chain)
        let receive = try await database.freshBitcoinFamilyHDAddress(walletID: walletID, chain: chain)
        let groupedHistory = Dictionary(grouping: results.flatMap(\.history), by: \.transactionHash)
        var references: [BitcoinHDTransactionReference] = []
        for (hash, entries) in groupedHistory {
            let height: Int64 = entries.contains(where: { $0.height <= 0 }) ? 0 : (entries.map(\.height).max() ?? 0)
            references.append(BitcoinHDTransactionReference(transactionHash: hash, height: height))
        }
        references.sort {
            let left = $0.height <= 0 ? Int64.max : $0.height
            let right = $1.height <= 0 ? Int64.max : $1.height
            return left == right ? $0.transactionHash < $1.transactionHash : left > right
        }
        let result = BitcoinFamilyHDDiscoveryResult(states: states, transactions: references,
            balance: states.reduce(.zero) { $0.adding($1.balanceAtomic) }, receiveAddress: receive)
        // Balance publication belongs to the coalesced scan, never a slower
        // history task that could overwrite a later balance refresh.
        try await database.saveBitcoinFamilyBalance(result.balance,
            material: Self.material(receive, chain: chain), walletID: walletID)
        return result
    }

    func sync(walletID: String, chain: BitcoinFamilyChain,
              onProgress: WalletSyncProgressHandler? = nil) async -> WalletChainSyncOutcome {
        var didPersistBalance = false
        do {
            let database = try databaseProvider()
            let result = try await discover(walletID: walletID, chain: chain)
            didPersistBalance = true
            await onProgress?(WalletSyncProgressEvent(source: .bitcoinFamily, networkID: chain.networkID, stage: .balancesPersisted))
            let material = Self.material(result.receiveAddress, chain: chain)
            async let price: Void = Self.refreshPrice(database: database, walletID: walletID, material: material)
            let history = try await BitcoinHDWalletSyncService(database: database, historyChain: chain).transactionEntries(
                references: Array(result.transactions.prefix(BitcoinFamilySyncService.maximumHistoryTransactions)),
                ownedAddresses: Dictionary(uniqueKeysWithValues: result.states.map { ($0.derived.scriptPubKey, $0.derived.address) }))
            try await database.saveBitcoinFamilySnapshot(BitcoinFamilyChainSnapshot(material: material,
                balanceAtomic: result.balance, history: history), walletID: walletID, preservingPersistedBalance: true)
            await price
            await publishWalletSyncDatasets(source: .bitcoinFamily, networkID: chain.networkID, onProgress: onProgress)
            return WalletChainSyncOutcome(source: .bitcoinFamily, didPersistData: true, failures: [])
        } catch is CancellationError { return .success(.bitcoinFamily, didPersistData: didPersistBalance) }
        catch {
            return WalletChainSyncOutcome(source: .bitcoinFamily, didPersistData: didPersistBalance,
                failures: [WalletChainSyncFailure(source: .bitcoinFamily, stage: didPersistBalance ? .historyEnrichment : .providerRead,
                    error: error, networkID: chain.networkID)])
        }
    }

    private static func refreshPrice(database: WalletDatabase, walletID: String, material: BitcoinFamilyAccountMaterial) async {
        _ = await BitcoinFamilySyncService(database: database).refreshValuation(material: material, walletID: walletID)
    }

    static func material(_ address: BitcoinHDDerivedAddress, chain: BitcoinFamilyChain) -> BitcoinFamilyAccountMaterial {
        BitcoinFamilyAccountMaterial(chain: chain, address: address.address, derivationPath: address.derivationPath,
            publicKey: address.publicKey.hexString, scriptPubKey: address.scriptPubKey)
    }
}
