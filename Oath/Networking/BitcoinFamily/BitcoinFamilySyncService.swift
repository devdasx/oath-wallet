import Foundation

actor BitcoinFamilySyncService {
    private struct IndexedHistoryCandidate: Sendable {
        let order: Int
        let hash: String
        let height: Int64
    }

    private struct IndexedHistoryResult: Sendable {
        let order: Int
        let entry: BitcoinFamilyHistoryEntry?
    }

    private struct ChainLoadOutcome: Sendable {
        let snapshot: BitcoinFamilyChainSnapshot
        let failures: [WalletChainSyncFailure]
    }

    private struct ChainSyncResult: Sendable {
        let networkID: String
        let outcome: WalletChainSyncOutcome
    }

    private struct BalanceSyncResult: Sendable {
        let didPersistData: Bool
        let failure: WalletChainSyncFailure?
    }

    private enum ChainPhaseResult: Sendable {
        case balance(
            BitcoinFamilyAtomicInteger?,
            WalletChainSyncFailure?
        )
        case snapshot(
            ChainLoadOutcome?,
            WalletChainSyncFailure?
        )
        case valuation(Bool)
    }

    enum Provider: String, Hashable, Sendable {
        case blockchair
        case blockCypher
        case electrum
    }

    static let shared = BitcoinFamilySyncService(
        databaseProvider: WalletDatabaseRuntime.require
    )
    private static let historyLookupConcurrency = 12
    static let maximumHistoryTransactions = 400
    static let snapshotProviderBaselineOrder: [Provider] = [
        .electrum,
        .blockchair,
        .blockCypher
    ]
    static let snapshotAttemptTimeoutSeconds: Double = 12
    static let snapshotOverallTimeoutSeconds: Double = 16

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let indexedAPI = BitcoinFamilyIndexedAPIClient.shared
    private let electrum = BitcoinFamilyElectrumClient.shared

    init(database: WalletDatabase) {
        databaseProvider = { database }
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
    }

    var database: WalletDatabase {
        get throws {
            try databaseProvider()
        }
    }

    private func familyHDOutcomeIfSupported(material: BitcoinFamilyAccountMaterial, walletID: String,
        onProgress: WalletSyncProgressHandler?) async -> WalletChainSyncOutcome? {
        guard material.chain.supportsFamilyHD else { return nil }
        do {
            let discovery = BitcoinFamilyHDDiscoveryService(database: try database)
            guard try await discovery.supports(walletID: walletID, chain: material.chain)
            else { return nil }
            return await discovery.sync(walletID: walletID, chain: material.chain,
                onProgress: onProgress)
        } catch is CancellationError { return .cancelled(.bitcoinFamily) }
        catch { return .failure(.bitcoinFamily, stage: .accountPreparation, error: error, networkID: material.chain.networkID) }
    }

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let materials: [BitcoinFamilyAccountMaterial]
        do {
            materials = try await database.ensureBitcoinFamilyAccounts(
                walletID: walletID
            )
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: .accountPreparation,
                error: error
            )
        }

        let results = await withTaskGroup(
            of: ChainSyncResult.self,
            returning: [WalletChainSyncOutcome].self
        ) { group in
            for material in materials {
                group.addTask {
                    if material.chain == .bitcoin,
                       let outcome = await self.bitcoinHDOutcomeIfSupported(
                        walletID: walletID, onProgress: onProgress
                       ) {
                        return ChainSyncResult(
                            networkID: material.chain.networkID,
                            outcome: outcome
                        )
                    }
                    if let outcome = await self.familyHDOutcomeIfSupported(material: material,
                        walletID: walletID, onProgress: onProgress) {
                        return ChainSyncResult(networkID: material.chain.networkID, outcome: outcome)
                    }
                    return await self.syncChain(
                        material,
                        walletID: walletID,
                        onProgress: onProgress
                    )
                }
            }
            var results: [WalletChainSyncOutcome] = []
            for await result in group {
                results.append(result.outcome)
            }
            return results
        }
        return WalletChainSyncOutcome(
            source: .bitcoinFamily,
            didPersistData: results.contains(where: \.didPersistData),
            failures: results.flatMap(\.failures)
        )
    }

    func sync(
        walletID: String,
        chain: BitcoinFamilyChain,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let materials: [BitcoinFamilyAccountMaterial]
        do {
            materials = try await database.ensureBitcoinFamilyAccounts(
                walletID: walletID
            )
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: .accountPreparation,
                error: error,
                networkID: chain.networkID
            )
        }
        guard let material = materials.first(where: { $0.chain == chain })
        else {
            return .failure(
                .bitcoinFamily,
                stage: .accountPreparation,
                error: WalletAssetDetailsRefreshError.unsupportedAsset,
                networkID: chain.networkID
            )
        }
        if let outcome = await familyHDOutcomeIfSupported(material: material, walletID: walletID, onProgress: onProgress) {
            return outcome
        }
        if chain == .bitcoin,
           let outcome = await bitcoinHDOutcomeIfSupported(
            walletID: walletID, onProgress: onProgress
           ) {
            return outcome
        }
        return await syncChain(
            material,
            walletID: walletID,
            onProgress: onProgress
        ).outcome
    }

    func refreshBalances(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let materials: [BitcoinFamilyAccountMaterial]
        do {
            materials = try await database.ensureBitcoinFamilyAccounts(
                walletID: walletID
            )
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: .accountPreparation,
                error: error
            )
        }

        let results = await withTaskGroup(
            of: BalanceSyncResult.self,
            returning: [BalanceSyncResult].self
        ) { group in
            for material in materials {
                group.addTask {
                    do {
                        try await self.refreshBalance(
                            material: material,
                            walletID: walletID,
                            onProgress: onProgress
                        )
                        return BalanceSyncResult(
                            didPersistData: true,
                            failure: nil
                        )
                    } catch is CancellationError {
                        return BalanceSyncResult(
                            didPersistData: false,
                            failure: nil
                        )
                    } catch {
                        return BalanceSyncResult(
                            didPersistData: false,
                            failure: WalletChainSyncFailure(
                                source: .bitcoinFamily,
                                stage: .providerRead,
                                error: error,
                                networkID: material.chain.networkID
                            )
                        )
                    }
                }
            }
            var completed: [BalanceSyncResult] = []
            for await result in group {
                completed.append(result)
            }
            return completed
        }
        return WalletChainSyncOutcome(
            source: .bitcoinFamily,
            didPersistData: results.contains(where: \.didPersistData),
            failures: results.compactMap(\.failure)
        )
    }

    func refreshBalance(
        material: BitcoinFamilyAccountMaterial,
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async throws {
        if material.chain.supportsFamilyHD {
            let discovery = BitcoinFamilyHDDiscoveryService(database: try database)
            if try await discovery.supports(walletID: walletID, chain: material.chain) {
                _ = try await discovery.discover(walletID: walletID, chain: material.chain)
                await onProgress?(WalletSyncProgressEvent(source: .bitcoinFamily,
                    networkID: material.chain.networkID, stage: .balancesPersisted))
                return
            }
        }
        if material.chain == .bitcoin,
           try await MuunRecoveryWalletSyncService.shared.supports(
            walletID: walletID
           ) {
            try await MuunRecoveryWalletSyncService.shared.refreshBalance(
                walletID: walletID,
                onProgress: onProgress
            )
            return
        }
        if material.chain == .bitcoin,
           try await BitcoinHDWalletSyncService.shared.supports(
            walletID: walletID
           ) {
            try await BitcoinHDWalletSyncService.shared.refreshBalance(
                walletID: walletID, onProgress: onProgress
            )
            return
        }
        if material.chain == .bitcoin,
           try await BitcoinHDWalletSyncService.shared.supportsSingleKey(
            walletID: walletID
           ) {
            _ = try await BitcoinHDWalletSyncService.shared
                .refreshSingleKeyBalanceSnapshot(
                    walletID: walletID,
                    onProgress: onProgress
                )
            return
        }
        let previousBalance = try await database
            .bitcoinFamilyPersistedBalance(
                walletID: walletID,
                chain: material.chain
            )
        let balance = try await loadElectrumBalance(
            material,
            previousBalance: previousBalance
        )
        try await database.saveBitcoinFamilyBalance(
            balance,
            material: material,
            walletID: walletID
        )
        await onProgress?(
            WalletSyncProgressEvent(
                source: .bitcoinFamily,
                networkID: material.chain.networkID,
                stage: .balancesPersisted
            )
        )
    }

    func accountMaterials(
        walletID: String
    ) async throws -> [BitcoinFamilyAccountMaterial] {
        try await database.ensureBitcoinFamilyAccounts(walletID: walletID)
    }

    private func syncChain(
        _ material: BitcoinFamilyAccountMaterial,
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> ChainSyncResult {
        var resolvedBalance: BitcoinFamilyAtomicInteger?
        var balanceFailure: WalletChainSyncFailure?
        var snapshotFailure: WalletChainSyncFailure?
        var failures: [WalletChainSyncFailure] = []
        var didPersistData = false
        let previousBalance = try? await database
            .bitcoinFamilyPersistedBalance(
                walletID: walletID,
                chain: material.chain
            )
        let exactBalanceTask = Task {
            try await self.loadElectrumBalance(
                material,
                previousBalance: previousBalance
            )
        }
        defer { exactBalanceTask.cancel() }

        await withTaskGroup(of: ChainPhaseResult.self) { group in
            group.addTask {
                do {
                    return .balance(
                        try await exactBalanceTask.value,
                        nil
                    )
                } catch {
                    return .balance(
                        nil,
                        WalletChainSyncFailure(
                            source: .bitcoinFamily,
                            stage: .providerRead,
                            error: error,
                            networkID: material.chain.networkID
                        )
                    )
                }
            }
            group.addTask {
                do {
                    return .snapshot(
                        try await self.loadWithFallback(
                            material,
                            exactBalanceTask: exactBalanceTask
                        ),
                        nil
                    )
                } catch {
                    return .snapshot(
                        nil,
                        WalletChainSyncFailure(
                            source: .bitcoinFamily,
                            stage: .providerRead,
                            error: error,
                            networkID: material.chain.networkID
                        )
                    )
                }
            }
            group.addTask {
                .valuation(
                    await self.refreshValuation(
                        material: material,
                        walletID: walletID
                    )
                )
            }

            for await phase in group {
                switch phase {
                case let .balance(balance, failure):
                    balanceFailure = failure
                    guard let balance else { continue }
                    resolvedBalance = balance
                    do {
                        try await database.saveBitcoinFamilyBalance(
                            balance,
                            material: material,
                            walletID: walletID
                        )
                        didPersistData = true
                        await onProgress?(
                            WalletSyncProgressEvent(
                                source: .bitcoinFamily,
                                networkID: material.chain.networkID,
                                stage: .balancesPersisted
                            )
                        )
                    } catch {
                        failures.append(
                            WalletChainSyncFailure(
                                source: .bitcoinFamily,
                                stage: .persistence,
                                error: error,
                                networkID: material.chain.networkID
                            )
                        )
                    }

                case let .snapshot(loadOutcome, failure):
                    snapshotFailure = failure
                    guard let loadOutcome else { continue }
                    let providerSnapshot = loadOutcome.snapshot
                    if resolvedBalance == nil {
                        do {
                            try Self.validateBalanceTransition(
                                previousBalance: previousBalance,
                                fetchedBalance:
                                    providerSnapshot.balanceAtomic,
                                hasHistoryEvidence:
                                    !providerSnapshot.history.isEmpty
                            )
                        } catch {
                            snapshotFailure = WalletChainSyncFailure(
                                source: .bitcoinFamily,
                                stage: .providerRead,
                                error: error,
                                networkID: material.chain.networkID
                            )
                            continue
                        }
                    }
                    let snapshot = BitcoinFamilyChainSnapshot(
                        material: providerSnapshot.material,
                        balanceAtomic:
                            resolvedBalance ?? providerSnapshot.balanceAtomic,
                        history: providerSnapshot.history
                    )
                    resolvedBalance = snapshot.balanceAtomic
                    failures.append(contentsOf: loadOutcome.failures)
                    do {
                        try await database.saveBitcoinFamilySnapshot(
                            snapshot,
                            walletID: walletID
                        )
                        didPersistData = true
                        await publishWalletSyncDatasets(
                            source: .bitcoinFamily,
                            networkID: material.chain.networkID,
                            onProgress: onProgress
                        )
                    } catch {
                        failures.append(
                            WalletChainSyncFailure(
                                source: .bitcoinFamily,
                                stage: .persistence,
                                error: error,
                                networkID: material.chain.networkID
                            )
                        )
                    }

                case let .valuation(didUpdate):
                    guard didUpdate else { continue }
                    await onProgress?(
                        WalletSyncProgressEvent(
                            source: .bitcoinFamily,
                            networkID: material.chain.networkID,
                            stage: .valuationPersisted
                        )
                    )
                }
            }
        }

        if Task.isCancelled, !didPersistData {
            return ChainSyncResult(
                networkID: material.chain.networkID,
                outcome: .cancelled(.bitcoinFamily)
            )
        }
        if let balanceFailure {
            // An indexed snapshot can still succeed without Electrum, but it
            // cannot prove that provider-observed mempool credits and debits
            // were included. Keep that incomplete pending-balance state
            // visible to retry/diagnostics instead of reporting full success.
            failures.append(balanceFailure)
        }
        if let snapshotFailure {
            // A balance-only refresh is still useful, but incomplete history
            // remains a real provider failure for diagnostics and retry.
            failures.append(snapshotFailure)
        }
        return ChainSyncResult(
            networkID: material.chain.networkID,
            outcome: WalletChainSyncOutcome(
                source: .bitcoinFamily,
                didPersistData: didPersistData,
                failures: failures
            )
        )
    }

    private func loadWithFallback(
        _ material: BitcoinFamilyAccountMaterial,
        exactBalanceTask:
            Task<BitcoinFamilyAtomicInteger, Error>? = nil
    ) async throws -> ChainLoadOutcome {
        let serviceID = "bitcoin_family_snapshot_\(material.chain.networkID)"
        let providerEndpoints: [(Provider, AdaptiveProviderEndpoint)] =
            Self.snapshotProviderBaselineOrder.enumerated().map {
                priority, provider in
                let endpointURL: URL = switch provider {
                case .electrum:
                    URL(
                        string:
                            "electrum://\(material.chain.networkID)"
                    )!
                case .blockchair:
                    URL(string: "https://api.blockchair.com")!
                case .blockCypher:
                    URL(string: "https://api.blockcypher.com")!
                }
                return (
                    provider,
                    AdaptiveProviderEndpoint(
                        serviceID: serviceID,
                        endpointURL: endpointURL,
                        baselinePriority: priority
                    )
                )
            }
        let endpoints = providerEndpoints.map(\.1)
        let providerByEndpoint = Dictionary(
            uniqueKeysWithValues: providerEndpoints.map { ($0.1, $0.0) }
        )
        let ordered = await AdaptiveProviderRouter.shared.ordered(endpoints)
        let overallDeadline = Date().addingTimeInterval(
            Self.snapshotOverallTimeoutSeconds
        )
        var errors: [Provider: String] = [:]
        var degradedOutcome: ChainLoadOutcome?

        for endpoint in ordered {
            try Task.checkCancellation()
            guard let provider = providerByEndpoint[endpoint] else { continue }
            let remaining = overallDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            let startedAt = Date()
            do {
                let outcome = try await ProviderRequestDeadline.run(
                    seconds: min(
                        Self.snapshotAttemptTimeoutSeconds,
                        remaining
                    ),
                    endpoint: endpoint
                ) {
                    switch provider {
                    case .blockchair:
                        return ChainLoadOutcome(
                            snapshot: try await self.indexedAPI.snapshot(
                                for: material
                            ),
                            failures: []
                        )
                    case .blockCypher:
                        return ChainLoadOutcome(
                            snapshot: try await self.indexedAPI
                                .fallbackSnapshot(for: material),
                            failures: []
                        )
                    case .electrum:
                        return try await self.loadFromElectrum(
                            material,
                            exactBalanceTask: exactBalanceTask
                        )
                    }
                }
                let latency = Self.providerLatency(from: startedAt)
                if outcome.failures.isEmpty {
                    await AdaptiveProviderRouter.shared.recordSuccess(
                        endpoint: endpoint,
                        latencyMilliseconds: latency
                    )
                    return outcome
                }
                await AdaptiveProviderRouter.shared.recordFailure(
                    endpoint: endpoint,
                    latencyMilliseconds: latency
                )
                if degradedOutcome == nil {
                    degradedOutcome = outcome
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await AdaptiveProviderRouter.shared.recordFailure(
                    endpoint: endpoint,
                    latencyMilliseconds: Self.providerLatency(
                        from: startedAt
                    )
                )
                errors[provider] =
                    BitcoinFamilyErrorDiagnostics.description(for: error)
            }
        }
        if let degradedOutcome {
            return degradedOutcome
        }
        throw BitcoinFamilySyncError.providersFailed(
            indexedAPI:
                errors[.blockchair] ?? "blockchair_unavailable",
            fallbackAPI:
                errors[.blockCypher] ?? "blockcypher_unavailable",
            electrum: errors[.electrum] ?? "electrum_unavailable"
        )
    }

    private func loadElectrumBalance(
        _ material: BitcoinFamilyAccountMaterial,
        previousBalance: BitcoinFamilyAtomicInteger? = nil
    ) async throws -> BitcoinFamilyAtomicInteger {
        let scriptHash = Self.electrumScriptHash(material)
        let values = try await electrum.callStringParameterBatch(
            chain: material.chain,
            method: "blockchain.scripthash.get_balance",
            parameters: [scriptHash]
        )
        guard values.count == 1,
              values[0].parameter == scriptHash,
              let object = values[0].value.object,
              let confirmed = object["confirmed"]?.atomicInteger,
              let unconfirmed = object["unconfirmed"]?.atomicInteger else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }
        let balance = try Self.combinedElectrumBalance(
            confirmed: confirmed,
            unconfirmed: unconfirmed
        )
        if previousBalance?.isPositive == true, balance.isZero {
            let history = try await electrum.call(
                chain: material.chain,
                method: "blockchain.scripthash.get_history",
                params: [AnyEncodable(scriptHash)],
                maximumResponseBytes:
                    BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
            )
            try Self.validateZeroBalanceHistoryEvidence(history)
        }
        return balance
    }

    func loadSnapshotWithFallback(
        _ material: BitcoinFamilyAccountMaterial
    ) async throws -> BitcoinFamilyChainSnapshot {
        try await loadWithFallback(material).snapshot
    }

    private func loadFromElectrum(
        _ material: BitcoinFamilyAccountMaterial,
        exactBalanceTask:
            Task<BitcoinFamilyAtomicInteger, Error>? = nil
    ) async throws -> ChainLoadOutcome {
        let hash = Self.electrumScriptHash(material)
        let balanceTask = exactBalanceTask ?? Task {
            try await self.loadElectrumBalance(material)
        }
        let ownsBalanceTask = exactBalanceTask == nil
        defer {
            if ownsBalanceTask {
                balanceTask.cancel()
            }
        }
        async let historyResult = electrum.call(
            chain: material.chain,
            method: "blockchain.scripthash.get_history",
            params: [AnyEncodable(hash)],
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        let balance = try await balanceTask.value
        let history: [BitcoinFamilyHistoryEntry]
        var historyFailure: WalletChainSyncFailure?
        do {
            guard let rawHistory = try await historyResult.array else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            var parsedHistory: [(String, Int64)] = []
            parsedHistory.reserveCapacity(rawHistory.count)
            for value in rawHistory {
                guard let item = value.object,
                      let transactionHash = item["tx_hash"]?.string,
                      !transactionHash.isEmpty,
                      let height = item["height"]?.exactInt64 else {
                    throw BitcoinFamilyElectrumError.invalidResponse
                }
                parsedHistory.append((transactionHash, height))
            }
            let indexedHistory = Self.completeIndexedHistory(parsedHistory)
            history = try await transactionEntries(
                indexedHistory: indexedHistory,
                material: material
            )
        } catch let error as CancellationError {
            throw error
        } catch {
            // A history provider failure must never discard a valid balance.
            // Existing cached transactions remain intact when an empty
            // history collection is persisted.
            history = []
            historyFailure = WalletChainSyncFailure(
                source: .bitcoinFamily,
                stage: .historyEnrichment,
                error: error,
                networkID: material.chain.networkID
            )
        }
        return ChainLoadOutcome(
            snapshot: BitcoinFamilyChainSnapshot(
                material: material,
                balanceAtomic: balance,
                history: history
            ),
            failures: [historyFailure].compactMap { $0 }
        )
    }

    private func transactionEntries(
        indexedHistory: [(String, Int64)],
        material: BitcoinFamilyAccountMaterial
    ) async throws -> [BitcoinFamilyHistoryEntry] {
        let candidates = indexedHistory.enumerated().map {
            IndexedHistoryCandidate(
                order: $0.offset,
                hash: $0.element.0,
                height: $0.element.1
            )
        }
        guard !candidates.isEmpty else { return [] }

        return try await withThrowingTaskGroup(
            of: IndexedHistoryResult.self
        ) { group in
            var nextCandidateIndex = 0

            func enqueueNextCandidate() {
                guard nextCandidateIndex < candidates.count else { return }
                let candidate = candidates[nextCandidateIndex]
                nextCandidateIndex += 1
                group.addTask {
                    do {
                        let entry = try await withBitcoinFamilyTimeout(
                            seconds: 8
                        ) {
                            try await self.transactionEntry(
                                hash: candidate.hash,
                                height: candidate.height,
                                material: material
                            )
                        }
                        return IndexedHistoryResult(
                            order: candidate.order,
                            entry: entry
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        return IndexedHistoryResult(
                            order: candidate.order,
                            entry: nil
                        )
                    }
                }
            }

            for _ in 0..<min(
                Self.historyLookupConcurrency,
                candidates.count
            ) {
                enqueueNextCandidate()
            }

            var results: [IndexedHistoryResult] = []
            while let result = try await group.next() {
                results.append(result)
                enqueueNextCandidate()
            }
            return results
                .sorted { $0.order < $1.order }
                .compactMap(\.entry)
        }
    }

    private func transactionEntry(
        hash: String,
        height: Int64,
        material: BitcoinFamilyAccountMaterial
    ) async throws -> BitcoinFamilyHistoryEntry {
        let rawValue = try await electrum.call(
            chain: material.chain,
            method: "blockchain.transaction.get",
            params: [AnyEncodable(hash), AnyEncodable(false)]
        )
        guard let rawHex = rawValue.string,
              let transaction = BitcoinRawTransaction(hex: rawHex) else {
            throw BitcoinFamilyElectrumError.invalidResponse
        }

        let received = transaction.outputs.reduce(
            BitcoinFamilyAtomicInteger.zero
        ) {
            $0.adding(
                $1.script == material.scriptPubKey ? $1.value : .zero
            )
        }
        var sent = BitcoinFamilyAtomicInteger.zero
        var totalInput = BitcoinFamilyAtomicInteger.zero
        var hasEveryInput = true
        var inputAddresses: [String] = []
        for input in transaction.inputs {
            try Task.checkCancellation()
            do {
                let previousValue = try await electrum.call(
                    chain: material.chain,
                    method: "blockchain.transaction.get",
                    params: [
                        AnyEncodable(input.previousHash),
                        AnyEncodable(false)
                    ]
                )
                guard let previousHex = previousValue.string,
                      let previous = BitcoinRawTransaction(hex: previousHex),
                      previous.outputs.indices.contains(input.previousIndex)
                else {
                    hasEveryInput = false
                    continue
                }
                let output = previous.outputs[input.previousIndex]
                totalInput = totalInput.adding(output.value)
                if let address = BitcoinFamilyScriptAddress.address(
                    from: output.script,
                    chain: material.chain
                ) {
                    inputAddresses.append(address)
                }
                if output.script == material.scriptPubKey {
                    sent = sent.adding(output.value)
                }
            } catch {
                hasEveryInput = false
            }
        }
        let totalOutput = transaction.outputs.reduce(
            BitcoinFamilyAtomicInteger.zero
        ) {
            $0.adding($1.value)
        }
        let candidateFee = totalInput.subtracting(totalOutput)
        let fee: BitcoinFamilyAtomicInteger?
        if hasEveryInput {
            guard !candidateFee.isNegative else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            fee = candidateFee
        } else {
            fee = nil
        }
        let net = received.subtracting(sent)
        let direction = BitcoinFamilyHistoryEntry.transferDirection(
            sent: sent, received: received, totalInput: totalInput,
            totalOutput: totalOutput, hasEveryInput: hasEveryInput
        )
        let amount = net.magnitude
        let timestamp = try? await blockTimestamp(
            height: height,
            chain: material.chain
        )
        let outputAddresses = transaction.outputs.compactMap {
            BitcoinFamilyScriptAddress.address(
                from: $0.script,
                chain: material.chain
            )
        }
        return BitcoinFamilyHistoryEntry(
            transactionHash: hash,
            height: height,
            amountAtomic: amount,
            feeAtomic: fee,
            direction: direction,
            timestamp: timestamp,
            identity: BitcoinFamilyTransactionIdentityMapper.identity(
                chain: material.chain,
                walletAddress: material.address,
                direction: direction,
                inputAddresses: inputAddresses,
                outputAddresses: outputAddresses
            )
        )
    }

    private func blockTimestamp(
        height: Int64,
        chain: BitcoinFamilyChain
    ) async throws -> Double? {
        guard height > 0 else { return nil }
        let value = try await electrum.call(
            chain: chain,
            method: "blockchain.block.header",
            params: [AnyEncodable(height)]
        )
        guard let header = value.string,
              let data = Data(bitcoinHex: header),
              data.count >= 72 else { return nil }
        let time = data[68..<72].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        return Double(time)
    }
}
