import Foundation

actor AptosSyncService {
    static let shared = AptosSyncService()

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var stage = WalletSyncFailureStage.accountPreparation
        do {
            let database = try WalletDatabaseRuntime.require()
            let material = try await database.ensureAptosAccount(
                walletID: walletID
            )
            stage = .providerRead
            let snapshot = try await AptosAPIClient.shared.loadSnapshot(
                material: material
            ) { partial in
                try await database.saveAptosSnapshot(
                    partial,
                    walletID: walletID
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .aptos,
                        stage: .balancesPersisted
                    )
                )
            }
            stage = .persistence
            try await database.saveAptosSnapshot(snapshot, walletID: walletID)
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .aptos,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .aptos,
                didPersistData: true,
                failures: snapshot.providerFailureCodes.map {
                    WalletChainSyncFailure(
                        source: .aptos,
                        stage: .providerRead,
                        kind: .providerUnavailable,
                        publicCode: $0
                    )
                }
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .aptos,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .aptos,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .aptos,
                        stage: stage,
                        error: error
                    )
                ]
            )
        }
    }
}
