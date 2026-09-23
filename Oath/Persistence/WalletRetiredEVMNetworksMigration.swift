import GRDB

extension WalletDatabase {
    static let retiredEVMNetworkIDs = [
        "fantom",
        "flare",
        "story_mainnet",
        "syscoin",
        "xai"
    ]

    static let retiredEVMChainIDs = [
        250,
        14,
        1_514,
        57,
        660_279
    ]

    static func registerRetiredEVMNetworksMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v29_remove_retired_evm_networks"
        ) { database in
            try retireRemovedEVMNetworks(database: database)
        }
    }

    static func retireRemovedEVMNetworks(
        database: Database
    ) throws {
        let networkIDs = retiredEVMNetworkIDs
        let chainIDs = retiredEVMChainIDs

        try DBNotificationRecord
            .filter(networkIDs.contains(Column("networkID")))
            .deleteAll(database)
        try DBContactAddressRecord
            .filter(networkIDs.contains(Column("networkID")))
            .deleteAll(database)
        try DBTransactionRecord
            .filter(networkIDs.contains(Column("networkID")))
            .deleteAll(database)
        try DBNFTCollectionRecord
            .filter(networkIDs.contains(Column("networkID")))
            .deleteAll(database)
        try DBDAppPermissionRecord
            .filter(chainIDs.contains(Column("chainID")))
            .deleteAll(database)
        try DBWalletAccountRecord
            .filter(networkIDs.contains(Column("networkID")))
            .deleteAll(database)
        try DBAssetRecord
            .filter(networkIDs.contains(Column("networkID")))
            .deleteAll(database)
        try DBAPICacheRecord
            .filter(Column("provider") == "asset-logo")
            .deleteAll(database)
        try DBNetworkRecord
            .filter(networkIDs.contains(Column("id")))
            .deleteAll(database)
    }
}
