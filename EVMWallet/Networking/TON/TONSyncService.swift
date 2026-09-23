import Foundation

actor TONSyncService {
    static let shared = TONSyncService()

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var stage = WalletSyncFailureStage.accountPreparation
        do {
            let database = try WalletDatabaseRuntime.require()
            let material = try await database.ensureTONAccount(
                walletID: walletID
            )
            stage = .providerRead
            let snapshot = try await TONAPIClient.shared.loadSnapshot(
                material: material
            ) { balanceSnapshot in
                try await database.saveTONSnapshot(
                    balanceSnapshot,
                    walletID: walletID
                )
                await persistence.markPersisted()
                await onProgress?(
                    WalletSyncProgressEvent(
                        source: .ton,
                        stage: .balancesPersisted
                    )
                )
            }
            stage = .persistence
            try await database.saveTONSnapshot(
                snapshot,
                walletID: walletID
            )
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .ton,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .ton,
                didPersistData: true,
                failures: snapshot.providerFailureCodes.map {
                    WalletChainSyncFailure(
                        source: .ton,
                        stage: .providerRead,
                        kind: .providerUnavailable,
                        publicCode: $0
                    )
                }
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .ton,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .ton,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .ton,
                        stage: stage,
                        error: error
                    )
                ]
            )
        }
    }
}
