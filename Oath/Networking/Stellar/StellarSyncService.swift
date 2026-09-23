import Foundation

actor StellarSyncService {
    static let shared = StellarSyncService()

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var stage = WalletSyncFailureStage.accountPreparation
        do {
            let database = try WalletDatabaseRuntime.require()
            let material = try await database.ensureStellarAccount(
                walletID: walletID
            )
            stage = .providerRead
            let snapshot = try await StellarAPIClient.shared.loadSnapshot(
                material: material
            ) { partial in
                try await database.saveStellarSnapshot(
                    partial,
                    walletID: walletID
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .stellar,
                        stage: .balancesPersisted
                    )
                )
            }
            stage = .persistence
            try await database.saveStellarSnapshot(snapshot, walletID: walletID)
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .stellar,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .stellar,
                didPersistData: true,
                failures: snapshot.providerFailureCodes.map {
                    WalletChainSyncFailure(
                        source: .stellar,
                        stage: .providerRead,
                        kind: .providerUnavailable,
                        publicCode: $0
                    )
                }
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .stellar,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .stellar,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .stellar,
                        stage: stage,
                        error: error
                    )
                ]
            )
        }
    }
}
