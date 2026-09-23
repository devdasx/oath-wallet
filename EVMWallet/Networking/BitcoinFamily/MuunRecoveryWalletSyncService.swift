import Foundation

actor MuunRecoveryWalletSyncService {
    static let shared = MuunRecoveryWalletSyncService(
        databaseProvider: WalletDatabaseRuntime.require
    )

    private static let maximumHistoryTransactions = 400
    private let databaseProvider:
        @Sendable () throws -> WalletDatabase
    private let discovery: MuunRecoveryDiscoveryService

    init(database: WalletDatabase) {
        databaseProvider = { database }
        discovery = MuunRecoveryDiscoveryService(database: database)
    }

    private init(
        databaseProvider:
            @escaping @Sendable () throws -> WalletDatabase
    ) {
        self.databaseProvider = databaseProvider
        discovery = .shared
    }

    private var database: WalletDatabase {
        get throws { try databaseProvider() }
    }

    func supports(walletID: String) async throws -> Bool {
        try await database.muunRecoveryWallet(walletID: walletID) != nil
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
            let result = try await discovery.discover(walletID: walletID)
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
                let owned = Dictionary(
                    uniqueKeysWithValues: result.states.map {
                        ($0.derived.scriptPubKey, $0.derived.address)
                    }
                )
                history = try await BitcoinHDWalletSyncService.shared
                    .transactionEntries(
                        references: Array(
                            result.transactions.prefix(
                                Self.maximumHistoryTransactions
                            )
                        ),
                        ownedAddresses: owned
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
    ) async throws -> MuunRecoveryDiscoveryResult {
        let result = try await discovery.refreshBalances(walletID: walletID)
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

    private nonisolated static func material(
        _ address: MuunRecoveryDerivedAddress
    ) -> BitcoinFamilyAccountMaterial {
        BitcoinFamilyAccountMaterial(
            chain: .bitcoin,
            address: address.address,
            derivationPath: MuunRecoveryKeyMaterial.accountMarker,
            publicKey: Data(address.scriptPubKey.dropFirst(2)).hexString,
            scriptPubKey: address.scriptPubKey
        )
    }
}
