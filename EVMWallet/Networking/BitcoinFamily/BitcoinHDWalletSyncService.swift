import Foundation

actor BitcoinHDWalletSyncService {
    private struct StandardBalanceRefreshOperation: Sendable {
        let id: UUID
        let task: Task<BitcoinHDDiscoveryResult, Error>
    }

    private struct SilentBalanceRefreshOperation: Sendable {
        let id: UUID
        let task: Task<Bool, Never>
    }

    static let shared = BitcoinHDWalletSyncService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let maximumHistoryTransactions = 400
    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let discovery: BitcoinHDDiscoveryService
    private let electrum = BitcoinFamilyElectrumClient.shared
    private let historyChain: BitcoinFamilyChain
    private var standardBalanceRefreshTasks: [
        String: StandardBalanceRefreshOperation
    ] = [:]
    private var silentBalanceRefreshTasks: [
        String: SilentBalanceRefreshOperation
    ] = [:]

    init(database: WalletDatabase, historyChain: BitcoinFamilyChain = .bitcoin) {
        self.historyChain = historyChain
        databaseProvider = { database }
        discovery = BitcoinHDDiscoveryService(database: database)
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        historyChain = .bitcoin
        discovery = .shared
    }

    private var database: WalletDatabase {
        get throws { try databaseProvider() }
    }

    func supports(walletID: String) async throws -> Bool {
        guard try await database.ensureBitcoinHDWallet(
            walletID: walletID
        ) else { return false }
        return true
    }

    func supportsSingleKey(walletID: String) async throws -> Bool {
        try await database.bitcoinSingleKeyWallet(
            walletID: walletID
        ) != nil
    }

    func syncSingleKey(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> WalletChainSyncOutcome {
        await BitcoinWalletValuationSync.run(
            databaseProvider: databaseProvider,
            onProgress: onProgress
        ) {
            await self.syncSingleKeyHistory(
                walletID: walletID,
                onProgress: onProgress
            )
        }
    }

    private func syncSingleKeyHistory(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> WalletChainSyncOutcome {
        do {
            let database = try self.database
            let result = try await BitcoinSingleKeyDiscoveryService(
                database: database
            ).discover(walletID: walletID)
            let material = Self.material(result.receiveAddress)
            try await database.saveBitcoinFamilyBalance(
                result.balanceAtomic,
                material: material,
                walletID: walletID
            )
            await onProgress?(
                WalletSyncProgressEvent(
                    source: .bitcoinFamily,
                    networkID: BitcoinFamilyChain.bitcoin.networkID,
                    stage: .balancesPersisted
                )
            )
            var failures: [WalletChainSyncFailure] = []
            let history: [BitcoinFamilyHistoryEntry]
            do {
                history = try await transactionEntries(
                    references: Array(
                        result.transactions.prefix(
                            Self.maximumHistoryTransactions
                        )
                    ),
                    states: result.states,
                    silentOutputs: [],
                    silentPaymentAddress: nil
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                history = []
                failures.append(
                    WalletChainSyncFailure(
                        source: .bitcoinFamily,
                        stage: .historyEnrichment,
                        error: error,
                        networkID: BitcoinFamilyChain.bitcoin.networkID
                    )
                )
            }
            try await database.saveBitcoinFamilySnapshot(
                BitcoinFamilyChainSnapshot(
                    material: material,
                    balanceAtomic: result.balanceAtomic,
                    history: history
                ),
                walletID: walletID
            )
            await publishWalletSyncDatasets(
                source: .bitcoinFamily,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .bitcoinFamily,
                didPersistData: true,
                failures: failures
            )
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: .providerRead,
                error: error,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        }
    }

    func refreshSingleKeyBalanceSnapshot(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async throws -> BitcoinHDDiscoveryResult {
        let database = try self.database
        let result = try await BitcoinSingleKeyDiscoveryService(
            database: database
        ).refreshBalances(walletID: walletID)
        try await database.saveBitcoinFamilyBalance(
            result.balanceAtomic,
            material: Self.material(result.receiveAddress),
            walletID: walletID
        )
        await onProgress?(
            WalletSyncProgressEvent(
                source: .bitcoinFamily,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                stage: .balancesPersisted
            )
        )
        return result
    }

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> WalletChainSyncOutcome {
        await BitcoinWalletValuationSync.run(
            databaseProvider: databaseProvider,
            onProgress: onProgress
        ) {
            await self.syncHistory(
                walletID: walletID,
                onProgress: onProgress
            )
        }
    }

    private func syncHistory(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> WalletChainSyncOutcome {
        do {
            // Home balance refresh and the live monitor both start during the
            // initial wallet load. Publish their shared balance-only scan
            // before the slower history discovery is allowed to use the same
            // Electrum workers.
            let refreshedBalance = try await refreshBalanceSnapshot(
                walletID: walletID,
                onProgress: onProgress
            )
            let result = try await discovery.discover(walletID: walletID)
            var failures: [WalletChainSyncFailure] = []
            let silentResult: BitcoinSilentPaymentWalletResult
            let silentRefreshSucceeded: Bool
            if try await database.bitcoinSilentPaymentAccount(
                walletID: walletID
            ) == nil {
                silentResult = try await BitcoinSilentPaymentSyncService
                    .shared.cachedResult(walletID: walletID)
                silentRefreshSucceeded = true
            } else {
                do {
                    silentResult = try await BitcoinSilentPaymentSyncService
                        .shared.refresh(walletID: walletID)
                    silentRefreshSucceeded = true
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    silentResult = try await BitcoinSilentPaymentSyncService
                        .shared.cachedResult(walletID: walletID)
                    silentRefreshSucceeded = false
                    failures.append(
                        WalletChainSyncFailure(
                            source: .bitcoinFamily,
                            stage: .providerRead,
                            error: error,
                            networkID: BitcoinFamilyChain.bitcoin.networkID
                        )
                    )
                }
            }
            let standardBalance = Self.totalBalance(
                of: refreshedBalance.states
            )
            let combinedBalance = standardBalance.adding(
                silentResult.balanceAtomic
            )
            let material = Self.material(result.receiveAddress)
            let balanceIsAuthoritative = silentRefreshSucceeded
                && silentResult.balanceIsAuthoritative
            if balanceIsAuthoritative {
                // Full history discovery may outlive a later pull refresh.
                // Never let its captured balance replace the newer value.
                // The coalesced balance workers own balance persistence and
                // will combine the newly refreshed Silent Payment state.
                scheduleSilentPaymentBalanceRefresh(
                    walletID: walletID,
                    onProgress: onProgress
                )
            }

            let history: [BitcoinFamilyHistoryEntry]
            do {
                history = try await transactionEntries(
                    references: Array(
                        Self.mergedReferences(
                            result.transactions,
                            silentResult.transactions
                        ).prefix(
                            Self.maximumHistoryTransactions
                        )
                    ),
                    states: result.states,
                    silentOutputs: silentResult.outputs,
                    silentPaymentAddress: try await database
                        .bitcoinSilentPaymentAccount(walletID: walletID)?
                        .address.encoded
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                history = []
                failures.append(
                    WalletChainSyncFailure(
                        source: .bitcoinFamily,
                        stage: .historyEnrichment,
                        error: error,
                        networkID: BitcoinFamilyChain.bitcoin.networkID
                    )
                )
            }
            // History publication is independent from Silent Payment scan
            // coverage. The fast balance refresh above already persisted the
            // latest standard balance plus every locally known Silent Payment
            // output, so this slower snapshot must never suppress history or
            // replace that newer balance.
            try await database.saveBitcoinFamilySnapshot(
                BitcoinFamilyChainSnapshot(
                    material: material,
                    balanceAtomic: combinedBalance,
                    history: history
                ),
                walletID: walletID,
                preservingPersistedBalance: true
            )
            await publishWalletSyncDatasets(
                source: .bitcoinFamily,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .bitcoinFamily,
                didPersistData: true,
                failures: failures
            )
        } catch is CancellationError {
            return .cancelled(.bitcoinFamily)
        } catch {
            return .failure(
                .bitcoinFamily,
                stage: .providerRead,
                error: error,
                networkID: BitcoinFamilyChain.bitcoin.networkID
            )
        }
    }

    func refreshBalance(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async throws {
        _ = try await refreshBalanceSnapshot(
            walletID: walletID,
            onProgress: onProgress
        )
    }

    func refreshBalanceSnapshot(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async throws -> BitcoinHDDiscoveryResult {
        async let standardResult = sharedStandardBalanceRefresh(
            walletID: walletID
        )
        async let silentBalance = BitcoinSilentPaymentSyncService.shared
            .cachedResult(walletID: walletID)
        let (result, silentResult) = try await (
            standardResult,
            silentBalance
        )
        let combined = try await publishKnownBalance(
            standardResult: result,
            silentResult: silentResult,
            walletID: walletID,
            onProgress: onProgress
        )
        scheduleSilentPaymentBalanceRefresh(
            walletID: walletID,
            onProgress: onProgress
        )
        return combined
    }

    /// Publishes the independently authoritative standard-address balance
    /// immediately, together with every Silent Payment output already known
    /// locally. Incomplete Silent Payment chain coverage means more outputs may
    /// still be discovered; it does not invalidate standard BIP44/49/84/86
    /// balances or previously persisted Silent Payment outputs.
    func publishKnownBalance(
        standardResult: BitcoinHDDiscoveryResult,
        silentResult: BitcoinSilentPaymentWalletResult,
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async throws -> BitcoinHDDiscoveryResult {
        let combined = BitcoinHDDiscoveryResult(
            states: standardResult.states,
            balanceAtomic: standardResult.balanceAtomic.adding(
                silentResult.balanceAtomic
            ),
            transactions: Self.mergedReferences(
                standardResult.transactions,
                silentResult.transactions
            ),
            receiveAddress: standardResult.receiveAddress
        )
        guard !combined.balanceAtomic.isNegative else {
            throw BitcoinHDDiscoveryError.invalidElectrumResponse
        }
        try await database.saveBitcoinFamilyBalance(
            combined.balanceAtomic,
            material: Self.material(standardResult.receiveAddress),
            walletID: walletID
        )
        await onProgress?(
            WalletSyncProgressEvent(
                source: .bitcoinFamily,
                networkID: BitcoinFamilyChain.bitcoin.networkID,
                stage: .balancesPersisted
            )
        )
        return combined
    }

    private func scheduleSilentPaymentBalanceRefresh(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) {
        Task(priority: .utility) {
            _ = await self.refreshSilentPaymentBalance(
                walletID: walletID,
                onProgress: onProgress
            )
        }
    }

    /// Refreshes Silent Payment discovery and the combined Bitcoin balance.
    /// Calls for the same wallet coalesce while different wallets remain
    /// independent so the all-wallet coordinator can use bounded concurrency.
    func refreshSilentPaymentBalance(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> Bool {
        if let operation = silentBalanceRefreshTasks[walletID] {
            return await operation.task.value
        }
        let operationID = UUID()
        let task = Task(priority: .utility) {
            await self.performSilentPaymentBalanceRefresh(
                walletID: walletID,
                onProgress: onProgress
            )
        }
        silentBalanceRefreshTasks[walletID] = SilentBalanceRefreshOperation(
            id: operationID,
            task: task
        )
        let result = await task.value
        clearSilentBalanceRefresh(
            walletID: walletID,
            operationID: operationID
        )
        return result
    }

    private func performSilentPaymentBalanceRefresh(
        walletID: String,
        onProgress: WalletSyncProgressHandler?
    ) async -> Bool {
        do {
            guard try await supports(walletID: walletID) else {
                // Electrum recovery wallets intentionally have no BIP352
                // account. Treat that supported no-op as completed rather
                // than making every background-processing request fail.
                return true
            }
            let silentResult = try await BitcoinSilentPaymentSyncService
                .shared.refresh(walletID: walletID)
            let result = try await sharedStandardBalanceRefresh(
                walletID: walletID
            )
            let balance = result.balanceAtomic.adding(
                silentResult.balanceAtomic
            )
            try await database.saveBitcoinFamilyBalance(
                balance,
                material: Self.material(result.receiveAddress),
                walletID: walletID
            )
            await onProgress?(
                WalletSyncProgressEvent(
                    source: .bitcoinFamily,
                    networkID: BitcoinFamilyChain.bitcoin.networkID,
                    stage: .balancesPersisted
                )
            )
            return true
        } catch {
            return false
        }
    }

    private func clearSilentBalanceRefresh(
        walletID: String,
        operationID: UUID
    ) {
        guard silentBalanceRefreshTasks[walletID]?.id == operationID else {
            return
        }
        silentBalanceRefreshTasks.removeValue(forKey: walletID)
    }

    private func sharedStandardBalanceRefresh(
        walletID: String
    ) async throws -> BitcoinHDDiscoveryResult {
        if let existing = standardBalanceRefreshTasks[walletID] {
            return try await existing.task.value
        }

        let operation = StandardBalanceRefreshOperation(
            id: UUID(),
            task: Task {
                try await discovery.refreshBalances(walletID: walletID)
            }
        )
        standardBalanceRefreshTasks[walletID] = operation
        do {
            let result = try await operation.task.value
            clearStandardBalanceRefresh(
                walletID: walletID,
                operationID: operation.id
            )
            return result
        } catch {
            clearStandardBalanceRefresh(
                walletID: walletID,
                operationID: operation.id
            )
            throw error
        }
    }

    private func clearStandardBalanceRefresh(
        walletID: String,
        operationID: UUID
    ) {
        guard standardBalanceRefreshTasks[walletID]?.id == operationID else {
            return
        }
        standardBalanceRefreshTasks.removeValue(forKey: walletID)
    }

    private nonisolated static func totalBalance(
        of states: [BitcoinHDAddressState]
    ) -> BitcoinFamilyAtomicInteger {
        states.reduce(.zero) { partial, state in
            partial.adding(state.balanceAtomic)
        }
    }

    private func transactionEntries(
        references: [BitcoinHDTransactionReference],
        states: [BitcoinHDAddressState],
        silentOutputs: [BitcoinSilentPaymentOutput],
        silentPaymentAddress: String?
    ) async throws -> [BitcoinFamilyHistoryEntry] {
        guard !references.isEmpty else { return [] }
        var ownedAddresses = Dictionary(
            uniqueKeysWithValues: states.map {
                ($0.derived.scriptPubKey, $0.derived.address)
            }
        )
        if let silentPaymentAddress {
            for output in silentOutputs {
                ownedAddresses[output.scriptPubKey] = silentPaymentAddress
            }
        }

        return try await transactionEntries(
            references: references,
            ownedAddresses: ownedAddresses
        )
    }

    func transactionEntries(
        references: [BitcoinHDTransactionReference],
        ownedAddresses: [Data: String]
    ) async throws -> [BitcoinFamilyHistoryEntry] {
        guard !references.isEmpty else { return [] }

        // Electrum history only contains transaction IDs and heights. Fetch
        // every root transaction once, then deduplicate every previous-output
        // transaction across the entire history before issuing a second
        // batch. This removes the former transaction-per-input N+1 path.
        let rootTransactions = try await rawTransactions(
            hashes: references.map(\.transactionHash)
        )
        let previousHashes = Self.orderedUnique(
            rootTransactions.values.flatMap { transaction in
                transaction.inputs.compactMap { input in
                    Self.isCoinbasePreviousHash(input.previousHash)
                        ? nil : input.previousHash
                }
            }
        )
        let missingPreviousHashes = previousHashes.filter {
            rootTransactions[$0] == nil
        }
        var previousTransactions = rootTransactions
        do {
            let fetched = try await rawTransactions(
                hashes: missingPreviousHashes
            )
            previousTransactions.merge(fetched) { current, _ in current }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if historyChain.supportsFamilyHD { throw error }
            // A missing previous transaction must not suppress otherwise
            // valid activity. Its fee and ownership remain unknown, matching
            // the previous best-effort behavior.
        }

        let timestamps: [Int64: Double]
        do {
            timestamps = try await blockTimestamps(
                heights: references.map(\.height)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            timestamps = [:]
        }

        return try references.compactMap { reference in
            try Task.checkCancellation()
            guard let transaction = rootTransactions[
                reference.transactionHash
            ] else { return nil }
            return try transactionEntry(
                reference: reference,
                transaction: transaction,
                previousTransactions: previousTransactions,
                ownedAddresses: ownedAddresses,
                timestamp: timestamps[reference.height]
            )
        }
    }

    private func transactionEntry(
        reference: BitcoinHDTransactionReference,
        transaction: BitcoinRawTransaction,
        previousTransactions: [String: BitcoinRawTransaction],
        ownedAddresses: [Data: String],
        timestamp: Double?
    ) throws -> BitcoinFamilyHistoryEntry {
        var received = BitcoinFamilyAtomicInteger.zero
        var receivedAddresses: [String] = []
        var outputAddresses: [String] = []
        for output in transaction.outputs {
            if let address = BitcoinFamilyScriptAddress.address(
                from: output.script,
                chain: historyChain
            ) {
                outputAddresses.append(address)
            }
            if let ownedAddress = ownedAddresses[output.script] {
                received = received.adding(output.value)
                receivedAddresses.append(ownedAddress)
            }
        }

        var sent = BitcoinFamilyAtomicInteger.zero
        var totalInput = BitcoinFamilyAtomicInteger.zero
        var hasEveryInput = true
        var inputAddresses: [String] = []
        var ownedInputAddresses: [String] = []
        for input in transaction.inputs {
            try Task.checkCancellation()
            guard !Self.isCoinbasePreviousHash(input.previousHash),
                  let previous = previousTransactions[input.previousHash],
                  previous.outputs.indices.contains(input.previousIndex) else {
                hasEveryInput = false
                continue
            }
            let previousOutput = previous.outputs[input.previousIndex]
            totalInput = totalInput.adding(previousOutput.value)
            if let address = BitcoinFamilyScriptAddress.address(
                from: previousOutput.script,
                chain: historyChain
            ) {
                inputAddresses.append(address)
            }
            if let ownedAddress = ownedAddresses[previousOutput.script] {
                sent = sent.adding(previousOutput.value)
                ownedInputAddresses.append(ownedAddress)
            }
        }

        let totalOutput = transaction.outputs.reduce(
            BitcoinFamilyAtomicInteger.zero
        ) { $0.adding($1.value) }
        let feeCandidate = totalInput.subtracting(totalOutput)
        let fee: BitcoinFamilyAtomicInteger?
        if hasEveryInput {
            guard !feeCandidate.isNegative else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
            fee = feeCandidate
        } else {
            fee = nil
        }

        let net = received.subtracting(sent)
        let direction = BitcoinFamilyHistoryEntry.transferDirection(
            sent: sent, received: received, totalInput: totalInput,
            totalOutput: totalOutput, hasEveryInput: hasEveryInput
        )
        let amount = net.magnitude
        let ownedInputAddressSet = Set(ownedInputAddresses)
        let receivedAddressSet = Set(receivedAddresses)
        let externalInputs = inputAddresses.filter {
            !ownedInputAddressSet.contains($0)
        }
        let externalOutputs = outputAddresses.filter {
            !receivedAddressSet.contains($0)
        }
        let identity = BitcoinFamilyTransactionIdentity(
            fromAddress: direction == "incoming"
                ? externalInputs.first ?? inputAddresses.first
                : ownedInputAddresses.first,
            toAddress: direction == "incoming"
                ? receivedAddresses.first
                : externalOutputs.first ?? receivedAddresses.first
        )
        return BitcoinFamilyHistoryEntry(
            transactionHash: reference.transactionHash,
            height: reference.height,
            amountAtomic: amount,
            feeAtomic: fee,
            direction: direction,
            timestamp: timestamp,
            identity: identity
        )
    }

    private func rawTransactions(
        hashes: [String]
    ) async throws -> [String: BitcoinRawTransaction] {
        let uniqueHashes = Self.orderedUnique(hashes)
        guard !uniqueHashes.isEmpty else { return [:] }
        let values = try await electrum.callStringParameterBatch(
            chain: historyChain,
            method: "blockchain.transaction.get",
            parameters: uniqueHashes,
            maximumResponseBytes:
                BitcoinFamilyElectrumClient.maximumHistoryResponseBytes
        )
        if historyChain.supportsFamilyHD {
            guard values.count == uniqueHashes.count,
                  Set(values.map(\.parameter)) == Set(uniqueHashes) else {
                throw BitcoinFamilyElectrumError.invalidResponse
            }
        }
        var transactions: [String: BitcoinRawTransaction] = [:]
        transactions.reserveCapacity(values.count)
        for result in values {
            try Task.checkCancellation()
            guard let rawHex = result.value.string,
                  let transaction = BitcoinRawTransaction(hex: rawHex),
                  transaction.transactionID.caseInsensitiveCompare(
                    result.parameter
                  ) == .orderedSame else {
                if historyChain.supportsFamilyHD { throw BitcoinFamilyElectrumError.invalidResponse }
                continue
            }
            transactions[result.parameter] = transaction
        }
        return transactions
    }

    private func blockTimestamps(
        heights: [Int64]
    ) async throws -> [Int64: Double] {
        let uniqueHeights = Self.orderedUnique(
            heights.filter { $0 > 0 }.map(String.init)
        )
        guard !uniqueHeights.isEmpty else { return [:] }
        let values = try await electrum.callStringParameterBatch(
            chain: historyChain,
            method: "blockchain.block.header",
            parameters: uniqueHeights,
            maximumResponseBytes: 262_144
        )
        var timestamps: [Int64: Double] = [:]
        timestamps.reserveCapacity(values.count)
        for result in values {
            try Task.checkCancellation()
            guard let height = Int64(result.parameter),
                  let header = result.value.string,
                  let data = Data(bitcoinHex: header),
                  data.count >= 72 else { continue }
            let time = data[68..<72].enumerated().reduce(UInt32(0)) {
                $0 | (UInt32($1.element) << UInt32($1.offset * 8))
            }
            timestamps[height] = Double(time)
        }
        return timestamps
    }

    private nonisolated static func orderedUnique(
        _ values: [String]
    ) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private nonisolated static func isCoinbasePreviousHash(
        _ hash: String
    ) -> Bool {
        hash.count == 64 && hash.allSatisfy { $0 == "0" }
    }

    private static func material(
        _ address: BitcoinHDDerivedAddress
    ) -> BitcoinFamilyAccountMaterial {
        BitcoinFamilyAccountMaterial(
            chain: .bitcoin,
            address: address.address,
            derivationPath: address.derivationPath,
            publicKey: address.publicKey.hexString,
            scriptPubKey: address.scriptPubKey
        )
    }

    private static func mergedReferences(
        _ standard: [BitcoinHDTransactionReference],
        _ silent: [BitcoinHDTransactionReference]
    ) -> [BitcoinHDTransactionReference] {
        Array(Set(standard + silent)).sorted {
            let leftPending = $0.height <= 0
            let rightPending = $1.height <= 0
            if leftPending != rightPending { return leftPending }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.transactionHash < $1.transactionHash
        }
    }
}
