import Foundation

extension AppRootView {
    static func synchronizeEVMWallet(
        database: WalletDatabase,
        walletID: String,
        address: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var failureStage = WalletSyncFailureStage.configuration
        do {
            let syncStartedAt = Date().timeIntervalSince1970
            let dataStore = WalletDataStore(database: database)
            let accounts = try await dataStore.accounts(walletID: walletID)
            let syncAccountID = accounts
                .filter {
                    AnkrAPIClient.supportsTokenLookup(
                        networkID: $0.networkID
                    )
                }
                .map(\.id)
                .sorted()
                .first
            let historyResource = "ankr_evm_history_v1"
            let priorHistoryState: DBSyncStateRecord?
            if let syncAccountID {
                priorHistoryState = try await dataStore.syncState(
                    accountID: syncAccountID,
                    resource: historyResource
                )
            } else {
                priorHistoryState = nil
            }
            let priorHistoryTimestamp = priorHistoryState?.cursor
                .flatMap(Int64.init)
                ?? priorHistoryState?.lastSuccessAt.map { Int64($0) }
            let historyFromTimestamp = priorHistoryTimestamp.map {
                max(0, $0 - 600)
            }
            let cachedHistoricalPrices = try await database
                .cachedAnkrHistoricalTokenPrices(walletID: walletID)
            let client = try AnkrAPIClient.localBuild()
            async let providerOutcome = client.loadWalletWithOutcome(
                address: address,
                historyFromTimestamp: historyFromTimestamp,
                cachedHistoricalTokenPrices: cachedHistoricalPrices
            ) { balanceSnapshot in
                try await database.saveWalletSnapshot(
                    balanceSnapshot,
                    address: address
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .evm,
                        stage: .balancesPersisted
                    )
                )
            }
            failureStage = .accountPreparation
            let trackedTargets = try await database
                .trackedEVMTokenBalanceTargets(walletID: walletID)
            failureStage = .trackedAssetRead
            let trackedBalances = try await
                TrackedEVMTokenBalanceService().loadBalances(
                    for: trackedTargets
                )
            failureStage = .providerRead
            let providerResult = try await providerOutcome
            try Task.checkCancellation()
            failureStage = .persistence
            try await database.saveWalletSnapshot(
                providerResult.snapshot,
                address: address,
                trackedTokenBalances: trackedBalances
            )
            try await database.saveAnkrHistoricalTokenPrices(
                providerResult.historicalTokenPrices,
                walletID: walletID
            )
            if let syncAccountID {
                let historySucceeded = providerResult.failures.isEmpty
                let historyState = DBSyncStateRecord(
                    accountID: syncAccountID,
                    resource: historyResource,
                    cursor: historySucceeded
                        ? String(Int64(syncStartedAt))
                        : priorHistoryState?.cursor,
                    lastAttemptAt: syncStartedAt,
                    lastSuccessAt: historySucceeded
                        ? syncStartedAt
                        : priorHistoryState?.lastSuccessAt,
                    nextAllowedAt: nil,
                    consecutiveFailureCount: historySucceeded
                        ? 0
                        : (priorHistoryState?.consecutiveFailureCount ?? 0)
                            + 1,
                    lastErrorCode: historySucceeded
                        ? nil
                        : "evm_history_partial"
                )
                try await dataStore.saveSyncState(historyState)
            }
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .evm,
                onProgress: onProgress
            )
            return .persistedEVM(
                providerFailures: providerResult.failures,
                failedTrackedTokenCount:
                    trackedBalances.failedHoldingIDs.count
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .evm,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .evm,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .evm,
                        stage: failureStage,
                        error: error
                    )
                ]
            )
        }
    }
}
