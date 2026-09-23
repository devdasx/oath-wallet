import Foundation
import GRDB

extension WalletDatabase {
    func seedReferenceData() throws {
        try Self.seedReferenceData(in: pool)
    }

    static func seedReferenceData(
        in writer: any DatabaseWriter,
        firstRunSettings: WalletApplicationSettings =
            WalletFirstRunSettings.current
    ) throws {
        let now = Date().timeIntervalSince1970
        let catalogSnapshot = try writer.write {
            database -> (tokens: [ReceiveToken], revision: Int64) in
            if try DBProfileRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) == nil {
                try DBProfileRecord(
                    id: Self.defaultProfileID,
                    displayName: nil,
                    createdAt: now,
                    updatedAt: now,
                    lastActiveAt: now
                ).insert(database)
            }

            if try DBUserSettingsRecord.fetchOne(
                database,
                key: Self.defaultProfileID
            ) == nil {
                try Self.defaultUserSettingsRecord(
                    updatedAt: now,
                    settings: firstRunSettings
                )
                    .insert(database)
            }

            for (index, network) in ReceiveNetworkCatalog.all.enumerated() {
                let providerIdentifier: String
                switch network.id {
                case "tron":
                    providerIdentifier = "ankr-tron"
                case "ton":
                    providerIdentifier = "tonapi"
                default:
                    providerIdentifier = network.id
                }
                let record = DBNetworkRecord(
                    id: network.id,
                    chainID: Int64(network.chainID),
                    nameKey: network.nameKey,
                    nativeSymbol: network.symbol,
                    trustWalletBlockchain: network.blockchain.rawValue,
                    rpcProviderIdentifier: providerIdentifier,
                    isMainnet: true,
                    isEnabled: true,
                    sortOrder: index,
                    createdAt: now,
                    updatedAt: now
                )
                if try DBNetworkRecord.fetchOne(
                    database,
                    key: network.id
                ) == nil {
                    try record.insert(database)
                } else {
                    try record.update(database)
                }
            }

            for (index, chain) in BitcoinFamilyChain.allCases.enumerated() {
                let record = DBNetworkRecord(
                    id: chain.networkID,
                    chainID: chain.databaseChainID,
                    nameKey: chain.nameKey,
                    nativeSymbol: chain.symbol,
                    trustWalletBlockchain: chain.blockchain.rawValue,
                    rpcProviderIdentifier: "electrum-\(chain.networkID)",
                    isMainnet: true,
                    isEnabled: true,
                    sortOrder: ReceiveNetworkCatalog.all.count + index,
                    createdAt: now,
                    updatedAt: now
                )
                if try DBNetworkRecord.fetchOne(
                    database,
                    key: chain.networkID
                ) == nil {
                    try record.insert(database)
                } else {
                    try record.update(database)
                }
            }

            let state = try WalletAssetCatalogPersistence.cacheState(
                in: database
            )
            guard state.didCompleteInitialSync else {
                return ([], state.revision)
            }
            do {
                return (
                    try WalletAssetCatalogPersistence
                        .loadCompleteCachedTokens(in: database),
                    state.revision
                )
            } catch {
                try DBAssetCatalogSyncStateRecord(
                    id: WalletAssetCatalogPersistence.syncStateID,
                    revision: state.revision,
                    didCompleteInitialSync: false,
                    updatedAt: now
                ).save(database)
                return ([], state.revision)
            }
        }
        ReceiveAssetCatalogRuntime.install(
            catalogSnapshot.tokens,
            revision: catalogSnapshot.revision
        )
    }
}
