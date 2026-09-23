import Foundation

actor NEARSyncService {
    static let shared = NEARSyncService()

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var stage = WalletSyncFailureStage.accountPreparation
        do {
            let database = try WalletDatabaseRuntime.require()
            let material = try await database.ensureNEARAccount(walletID: walletID)
            stage = .providerRead
            let snapshot = try await NEARAPIClient.shared.loadSnapshot(
                material: material
            ) { balanceSnapshot in
                try await database.saveNEARSnapshot(
                    balanceSnapshot,
                    walletID: walletID
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .near,
                        stage: .balancesPersisted
                    )
                )
            }
            stage = .persistence
            try await database.saveNEARSnapshot(snapshot, walletID: walletID)
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .near,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .near,
                didPersistData: true,
                failures: snapshot.providerFailureCodes.map {
                    WalletChainSyncFailure(
                        source: .near,
                        stage: .providerRead,
                        kind: .providerUnavailable,
                        publicCode: $0
                    )
                }
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .near,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .near,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .near,
                        stage: stage,
                        error: error
                    )
                ]
            )
        }
    }
}
