import Foundation

actor SuiSyncService {
    static let shared = SuiSyncService()

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var stage = WalletSyncFailureStage.accountPreparation
        do {
            let database = try WalletDatabaseRuntime.require()
            let material = try await database.ensureSuiAccount(
                walletID: walletID
            )
            stage = .providerRead
            let snapshot = try await SuiAPIClient.shared.loadSnapshot(
                material: material
            ) { balanceSnapshot in
                try await database.saveSuiSnapshot(
                    balanceSnapshot,
                    walletID: walletID
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .sui,
                        stage: .balancesPersisted
                    )
                )
            }
            stage = .persistence
            try await database.saveSuiSnapshot(
                snapshot,
                walletID: walletID
            )
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .sui,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .sui,
                didPersistData: true,
                failures: snapshot.providerFailureCodes.map {
                    WalletChainSyncFailure(
                        source: .sui,
                        stage: .providerRead,
                        kind: .providerUnavailable,
                        publicCode: $0
                    )
                }
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .sui,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .sui,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .sui,
                        stage: stage,
                        error: error
                    )
                ]
            )
        }
    }
}
