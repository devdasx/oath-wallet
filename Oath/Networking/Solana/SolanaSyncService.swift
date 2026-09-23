import Foundation

actor SolanaSyncService {
    static let shared = SolanaSyncService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private let databaseProvider:
        @Sendable () throws -> WalletDatabase

    init(database: WalletDatabase) {
        databaseProvider = { database }
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
    }

    func sync(
        walletID: String,
        requiresFresh: Bool = false,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        do {
            let database = try databaseProvider()
            return await SolanaSyncCoordinator.shared.sync(
                key: .init(databaseID: ObjectIdentifier(database), walletID: walletID),
                requiresFresh: requiresFresh,
                onProgress: onProgress
            ) { progress in
                await self.performSync(walletID: walletID, database: database, onProgress: progress)
            }
        } catch {
            return .failure(.solana, stage: .accountPreparation, error: error)
        }
    }

    private func performSync(
        walletID: String,
        database: WalletDatabase,
        onProgress: @escaping WalletSyncProgressHandler
    ) async -> WalletChainSyncOutcome {
        let operationID = UUID()
        var failureStage = WalletSyncFailureStage.accountPreparation
        var didPersistData = false
        do {
            try Task.checkCancellation()
            let accounts = try await database.ensureSolanaAccounts(
                walletID: walletID
            )
            let historyCursors = try await database.solanaHistoryCursors(
                walletID: walletID
            )
            failureStage = .providerRead
            try Task.checkCancellation()
            let balanceSnapshot =
                try await SolanaAPIClient.shared.loadBalanceSnapshot(
                    accounts: accounts,
                    historyCursors: historyCursors
                )
            let balanceEligibilityByMint =
                await classifiedEligibility(
                    snapshot: balanceSnapshot,
                    database: database
                )
            let classifiedBalanceSnapshot =
                try SolanaTokenEligibilityPolicy.enrichedSnapshot(
                    balanceSnapshot,
                    eligibilityByMint: balanceEligibilityByMint
                )
            failureStage = .persistence
            try Task.checkCancellation()
            try await database.saveSolanaSnapshot(
                classifiedBalanceSnapshot,
                walletID: walletID,
                eligibilityByMint: balanceEligibilityByMint,
                operationID: operationID
            )
            didPersistData = true
            AssetCatalogSyncService.schedule(database: database)
            await onProgress(
                WalletSyncProgressEvent(
                    source: .solana,
                    stage: .balancesPersisted
                )
            )
            try Task.checkCancellation()

            failureStage = .historyEnrichment
            let snapshot = try await SolanaAPIClient.shared.loadSnapshot(
                accounts: accounts,
                addressSnapshots: balanceSnapshot.addressSnapshots,
                historyCursors: historyCursors,
                operationID: operationID
            )
            let eligibilityByMint =
                await classifiedEligibility(
                    snapshot: snapshot,
                    database: database
                )
            let classifiedSnapshot =
                try SolanaTokenEligibilityPolicy.enrichedSnapshot(
                    snapshot,
                    eligibilityByMint: eligibilityByMint
                )
            failureStage = .persistence
            try Task.checkCancellation()
            try await database.saveSolanaSnapshot(
                classifiedSnapshot,
                walletID: walletID,
                eligibilityByMint: eligibilityByMint,
                operationID: operationID
            )
            await publishWalletSyncDatasets(
                source: .solana,
                onProgress: onProgress
            )
            return .success(.solana)
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .solana,
                didPersistData: didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .solana,
                didPersistData: didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .solana,
                        stage: failureStage,
                        error: error
                    )
                ]
            )
        }
    }

    private func classifiedEligibility(
        snapshot: SolanaWalletSnapshot,
        database: WalletDatabase
    ) async -> [String: SolanaTokenEligibility] {
        let observedMints = Set(
            snapshot.addressSnapshots
                .flatMap(\.tokenBalances)
                .map(\.mint)
                + snapshot.history.compactMap(\.mint)
                + Array(SolanaTokenCatalog.byMint.keys)
        )
        return await database.resolveSolanaTokenEligibility(
            mints: observedMints
        )
    }
}
