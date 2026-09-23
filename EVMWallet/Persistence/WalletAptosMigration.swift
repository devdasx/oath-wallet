import Foundation
import GRDB

extension WalletDatabase {
    static func registerAptosMainnetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v36_add_aptos_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: AptosConstants.networkID,
                chainID: Int64(AptosConstants.databaseChainID),
                nameKey: "network.aptos.name",
                nativeSymbol: AptosConstants.nativeSymbol,
                trustWalletBlockchain: WalletBlockchain.aptos.rawValue,
                rpcProviderIdentifier: "aptos-mainnet-rest-indexer",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_700,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }
    }
}
