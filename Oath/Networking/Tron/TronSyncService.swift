import Foundation

actor TronSyncService {
    typealias AccountLoader =
        @Sendable (String) async throws -> TronAccountMaterial
    typealias TrackedTokenLoader =
        @Sendable (String) async throws -> [TronTrackedToken]
    typealias SnapshotLoader =
        @Sendable (
            TronAccountMaterial,
            [TronTrackedToken]
        ) async throws -> TronWalletSnapshot
    typealias ProgressiveSnapshotLoader =
        @Sendable (
            TronAccountMaterial,
            [TronTrackedToken],
            (@Sendable (TronWalletSnapshot) async throws -> Void)?
        ) async throws -> TronWalletSnapshot
    typealias SnapshotSaver =
        @Sendable (TronWalletSnapshot, String) async throws -> Void

    static let shared = TronSyncService(
        accountLoader: { walletID in
            try await WalletDatabaseRuntime.require()
                .ensureTronAccount(walletID: walletID)
        },
        trackedTokenLoader: { walletID in
            try await WalletDatabaseRuntime.require()
                .trackedTronTokens(walletID: walletID)
        },
        progressiveSnapshotLoader: {
            material,
            trackedTokens,
            onNativeBalance in
            try await TronAPIClient.shared.loadSnapshot(
                material: material,
                trackedTokens: trackedTokens,
                onNativeBalance: onNativeBalance
            )
        },
        snapshotSaver: { snapshot, walletID in
            try await WalletDatabaseRuntime.require()
                .saveTronSnapshot(
                    snapshot,
                    walletID: walletID
                )
        }
    )

    private let accountLoader: AccountLoader
    private let trackedTokenLoader: TrackedTokenLoader
    private let snapshotLoader: ProgressiveSnapshotLoader
    private let snapshotSaver: SnapshotSaver

    init(database: WalletDatabase) {
        accountLoader = { walletID in
            try await database.ensureTronAccount(walletID: walletID)
        }
        trackedTokenLoader = { walletID in
            try await database.trackedTronTokens(walletID: walletID)
        }
        snapshotLoader = {
            material,
            trackedTokens,
            onNativeBalance in
            try await TronAPIClient.shared.loadSnapshot(
                material: material,
                trackedTokens: trackedTokens,
                onNativeBalance: onNativeBalance
            )
        }
        snapshotSaver = { snapshot, walletID in
            try await database.saveTronSnapshot(
                snapshot,
                walletID: walletID
            )
        }
    }

    init(
        accountLoader: @escaping AccountLoader,
        trackedTokenLoader: @escaping TrackedTokenLoader,
        snapshotLoader: @escaping SnapshotLoader,
        snapshotSaver: @escaping SnapshotSaver
    ) {
        self.accountLoader = accountLoader
        self.trackedTokenLoader = trackedTokenLoader
        self.snapshotLoader = {
            material,
            trackedTokens,
            _ in
            try await snapshotLoader(material, trackedTokens)
        }
        self.snapshotSaver = snapshotSaver
    }

    private init(
        accountLoader: @escaping AccountLoader,
        trackedTokenLoader: @escaping TrackedTokenLoader,
        progressiveSnapshotLoader:
            @escaping ProgressiveSnapshotLoader,
        snapshotSaver: @escaping SnapshotSaver
    ) {
        self.accountLoader = accountLoader
        self.trackedTokenLoader = trackedTokenLoader
        snapshotLoader = progressiveSnapshotLoader
        self.snapshotSaver = snapshotSaver
    }

    func sync(
        walletID: String,
        onProgress: WalletSyncProgressHandler? = nil
    ) async -> WalletChainSyncOutcome {
        let persistence = WalletSyncPersistenceTracker()
        var failureStage = WalletSyncFailureStage.accountPreparation
        do {
            let material = try await accountLoader(walletID)
            try Task.checkCancellation()
            let trackedTokens = try await trackedTokenLoader(walletID)
            try Task.checkCancellation()
            failureStage = .providerRead
            let snapshot = try await snapshotLoader(
                material,
                trackedTokens,
                { nativeSnapshot in
                    try await self.snapshotSaver(
                        nativeSnapshot,
                        walletID
                    )
                    await persistence.markPersisted()
                    await onProgress?(
                        WalletSyncProgressEvent(
                            source: .tron,
                            stage: .balancesPersisted
                        )
                    )
                }
            )
            try Task.checkCancellation()
            failureStage = .persistence
            try await snapshotSaver(snapshot, walletID)
            await persistence.markPersisted()
            await publishWalletSyncDatasets(
                source: .tron,
                onProgress: onProgress
            )
            return WalletChainSyncOutcome(
                source: .tron,
                didPersistData: true,
                failures: snapshot.providerFailures
            )
        } catch is CancellationError {
            return WalletChainSyncOutcome(
                source: .tron,
                didPersistData: await persistence.didPersistData,
                failures: []
            )
        } catch {
            return WalletChainSyncOutcome(
                source: .tron,
                didPersistData: await persistence.didPersistData,
                failures: [
                    WalletChainSyncFailure(
                        source: .tron,
                        stage: failureStage,
                        error: error
                    )
                ]
            )
        }
    }
}
