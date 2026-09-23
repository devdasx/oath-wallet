import Foundation
import GRDB

extension WalletDatabase {
    static func registerNEARMainnetMigration(
        on migrator: inout DatabaseMigrator
    ) {
        migrator.registerMigration("v35_add_near_mainnet") { database in
            let now = Date().timeIntervalSince1970
            try DBNetworkRecord(
                id: NEARConstants.networkID,
                chainID: Int64(NEARConstants.databaseChainID),
                nameKey: "network.near.name",
                nativeSymbol: NEARConstants.nativeSymbol,
                trustWalletBlockchain: WalletBlockchain.near.rawValue,
                rpcProviderIdentifier: "ankr-near-jsonrpc",
                isMainnet: true,
                isEnabled: true,
                sortOrder: 10_600,
                createdAt: now,
                updatedAt: now
            ).save(database)
        }
    }
}
