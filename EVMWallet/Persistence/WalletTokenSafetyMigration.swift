import GRDB

extension WalletDatabase {
    static func registerTokenSafetyCleanupMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration(
            "v30_token_safety_cleanup"
        ) { database in
            try removeHardDeniedAssets(database: database)
        }
    }

    static func removeHardDeniedAssets(
        database: Database
    ) throws {
        let assets = try DBAssetRecord.fetchAll(database)
        let unsafeAssetIDs = assets.compactMap { asset -> String? in
            let hardDenied = TokenSafetyPolicy.isHardDenied(
                networkID: asset.networkID,
                contractAddress: asset.normalizedContractAddress
            )
            guard
                hardDenied
                    || (
                        asset.isSpam
                            && asset.networkID
                                != SolanaConstants.networkID
                    )
            else {
                return nil
            }
            return asset.id
        }
        guard !unsafeAssetIDs.isEmpty else {
            return
        }

        try DBTransactionRecord
            .filter(unsafeAssetIDs.contains(Column("assetID")))
            .deleteAll(database)
        try DBAssetRecord
            .filter(unsafeAssetIDs.contains(Column("id")))
            .deleteAll(database)

        let deniedSolanaMints = assets.compactMap { asset -> String? in
            guard
                asset.networkID == SolanaConstants.networkID,
                TokenSafetyPolicy.isHardDenied(
                    networkID: SolanaConstants.networkID,
                    contractAddress:
                        asset.normalizedContractAddress
                )
            else {
                return nil
            }
            return asset.normalizedContractAddress
        }
        if !deniedSolanaMints.isEmpty {
            try DBSolanaTokenEligibilityRecord
                .filter(deniedSolanaMints.contains(Column("mint")))
                .deleteAll(database)
        }
    }
}
