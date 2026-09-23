import Foundation

actor XRPSyncService {
    static let shared = XRPSyncService()

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var stage = WalletSyncFailureStage.accountPreparation
        do {
            let database = try WalletDatabaseRuntime.require()
            let material = try await database.ensureXRPAccount(
                walletID: walletID
            )
            let accountID = "\(walletID):xrp:0"
            let historyResource = "xrp_history_ledger_v1"
            let dataStore = WalletDataStore(database: database)
            let priorHistoryState = try await dataStore.syncState(
                accountID: accountID,
                resource: historyResource
            )
            let historyLedgerMinimum = priorHistoryState?.cursor
                .flatMap(Int64.init)
                .map { $0 + 1 }
            let syncStartedAt = Date().timeIntervalSince1970
            stage = .providerRead
            let snapshot = try await XRPAPIClient.shared.loadSnapshot(
                material: material,
                historyLedgerMinimum: historyLedgerMinimum
            ) { balanceSnapshot in
                try await database.saveXRPSnapshot(
                    balanceSnapshot,
                    walletID: walletID
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .xrp,
                        stage: .balancesPersisted
                    )
                )
            }
            stage = .persistence
            try await database.saveXRPSnapshot(
                snapshot,
                walletID: walletID
            )
            let historySucceeded = snapshot.historyIsAuthoritative
            try await dataStore.saveSyncState(
                DBSyncStateRecord(
                    accountID: accountID,
                    resource: historyResource,
                    cursor: historySucceeded
                        ? snapshot.historyLedgerWatermark.map(String.init)
                            ?? priorHistoryState?.cursor
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
                        : "xrp_history_partial"
                )
            )
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .xrp,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .xrp,
                didPersistData: true,
                failures: snapshot.providerFailureCodes.map {
                    WalletChainSyncFailure(
                        source: .xrp,
                        stage: .providerRead,
                        kind: .providerUnavailable,
                        publicCode: $0
                    )
                }
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .xrp,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .xrp,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .xrp,
                        stage: stage,
                        error: error
                    )
                ]
            )
        }
    }
}
